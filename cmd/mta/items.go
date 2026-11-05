package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// The items commands are a thin client over the library API. They keep no
// local state, never print the API key, and always show and accept full ids as
// <type>:<uuid> references so output from one command feeds the next.

type itemKind struct {
	name        string // CLI prefix: video, audio, pdf
	libraryType string // /library/items item_type
	prefType    string // /library/items/:type/... path segment
	colType     string // collection item_type
	path        string // detail route prefix
}

var itemKinds = map[string]itemKind{
	"video": {name: "video", libraryType: "youtube", prefType: "transcript", colType: "transcript", path: "/transcripts/"},
	"audio": {name: "audio", libraryType: "audio", prefType: "audio", colType: "audio", path: "/audio/transcriptions/"},
	"pdf":   {name: "pdf", libraryType: "pdf", prefType: "pdf", colType: "pdf", path: "/pdf/extractions/"},
}

type itemRef struct {
	kind itemKind
	id   string
}

func (r itemRef) String() string { return r.kind.name + ":" + r.id }

func kindFromLibraryType(libraryType string) (itemKind, bool) {
	for _, kind := range itemKinds {
		if kind.libraryType == libraryType {
			return kind, true
		}
	}
	return itemKind{}, false
}

func looksLikeUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i, r := range value {
		switch {
		case i == 8 || i == 13 || i == 18 || i == 23:
			if r != '-' {
				return false
			}
		case !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F'):
			return false
		}
	}
	return true
}

func parseItemRef(value string) (itemRef, error) {
	prefix, id, found := strings.Cut(value, ":")
	if !found {
		return itemRef{}, fmt.Errorf("invalid reference %q; use video:<id>, audio:<id>, or pdf:<id> with the full id", value)
	}
	switch strings.ToLower(prefix) {
	case "youtube", "transcript":
		prefix = "video"
	}
	kind, ok := itemKinds[strings.ToLower(prefix)]
	if !ok {
		return itemRef{}, fmt.Errorf("invalid reference %q; type must be video, audio, or pdf", value)
	}
	if !looksLikeUUID(id) {
		return itemRef{}, fmt.Errorf("invalid reference %q; use the full 36-character id, not a shortened one", value)
	}
	return itemRef{kind: kind, id: strings.ToLower(id)}, nil
}

// ── HTTP ──

var apiHTTP = &http.Client{Timeout: 60 * time.Second}

// apiCall sends one JSON request and returns the body of a 2xx response.
func apiCall(method, path string, payload interface{}) ([]byte, error) {
	var reader io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(encoded)
	}
	req, err := http.NewRequest(method, apiBase+path, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-API-Key", apiKey)
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := apiHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	const maxBytes = 64 << 20
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxBytes {
		return nil, errors.New("API response exceeded 64 MB")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, apiStatusError{status: resp.StatusCode, body: strings.TrimSpace(string(data))}
	}
	return data, nil
}

func apiGetJSON(path string, out interface{}) error {
	data, err := apiCall(http.MethodGet, path, nil)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("unexpected response from %s: %w", path, err)
	}
	return nil
}

// ── Flag parsing ──

// parseInterspersed lets flags appear before or after positional arguments,
// which is how agents tend to write commands.
func parseInterspersed(flags *flag.FlagSet, args []string) ([]string, error) {
	var positional []string
	for {
		if err := flags.Parse(args); err != nil {
			return nil, err
		}
		args = flags.Args()
		if len(args) == 0 {
			return positional, nil
		}
		positional = append(positional, args[0])
		args = args[1:]
	}
}

func newFlags(name string, stderr io.Writer) *flag.FlagSet {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	return flags
}

func checkOutput(output string) error {
	if output != "text" && output != "json" {
		return fmt.Errorf("--output must be text or json")
	}
	return nil
}

func writeJSON(stdout io.Writer, value interface{}) error {
	encoder := json.NewEncoder(stdout)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}

// ── Dispatcher ──

func cmdItems(args []string) error { return runItems(args, os.Stdout, os.Stderr) }

const itemsUsage = `usage: mta items <command>

  list [--since DATE] [--type video|audio|pdf] [--status S] [--limit N]
  search <query> [--type T] [--limit N]
  get <type:id> [--format md|json]
  rename <type:id> <name>                 audio only
  tag <type:id> [--add a,b] [--remove c] [--set a,b]
  favorite <type:id> [--off]
  archive <type:id> [--off]
  collection <type:id> (--add NAME|ID | --remove NAME|ID)
  retry <type:id>                         audio only
  summarize <type:id> [--length short|medium|detailed]
  chat <type:id> <message>
  delete <type:id> --yes

Every command accepts --output text|json. Ids are always the full id.`

func runItems(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		fmt.Fprintln(stderr, itemsUsage)
		if len(args) == 0 {
			return errors.New("items needs a command")
		}
		return nil
	}
	if apiKey == "" {
		return errors.New("MTA_API_KEY is required")
	}
	rest := args[1:]
	switch args[0] {
	case "list":
		return itemsList(rest, stdout, stderr)
	case "search":
		return itemsSearch(rest, stdout, stderr)
	case "get":
		return itemsGet(rest, stdout, stderr)
	case "rename":
		return itemsRename(rest, stdout, stderr)
	case "tag":
		return itemsTag(rest, stdout, stderr)
	case "favorite":
		return itemsToggle(rest, stdout, stderr, "favorite")
	case "archive":
		return itemsToggle(rest, stdout, stderr, "archived")
	case "collection":
		return itemsCollection(rest, stdout, stderr)
	case "retry":
		return itemsRetry(rest, stdout, stderr)
	case "summarize":
		return itemsSummarize(rest, stdout, stderr)
	case "chat":
		return itemsChat(rest, stdout, stderr)
	case "delete":
		return itemsDelete(rest, stdout, stderr)
	default:
		return fmt.Errorf("unknown items command %q", args[0])
	}
}

// ── list and search ──

type itemCollection struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Color string `json:"color"`
}

type libraryItem struct {
	Excerpt       string           `json:"excerpt,omitempty"`
	Waveform      []int            `json:"waveform,omitempty"`
	Collections   []itemCollection `json:"collections"`
	ID            string           `json:"id"`
	ItemType      string           `json:"item_type"`
	Title         string           `json:"title"`
	Status        string           `json:"status"`
	SummaryStatus string           `json:"summary_status"`
	WordCount     int              `json:"word_count"`
	Favorite      bool             `json:"favorite"`
	Archived      bool             `json:"archived"`
	Tags          json.RawMessage  `json:"tags"`
	CreatedAt     string           `json:"created_at"`
}

// itemSummary is the stable JSON shape for list and search results.
type itemSummary struct {
	Excerpt     string           `json:"excerpt,omitempty"`
	Waveform    []int            `json:"waveform,omitempty"`
	Collections []itemCollection `json:"collections"`
	Ref         string           `json:"ref"`
	ID          string           `json:"id"`
	Type        string           `json:"type"`
	Title       string           `json:"title"`
	Status      string           `json:"status"`
	WordCount   int              `json:"word_count"`
	Favorite    bool             `json:"favorite"`
	Archived    bool             `json:"archived"`
	Tags        []string         `json:"tags"`
	CreatedAt   string           `json:"created_at"`
}

func summarizeLibraryItem(item libraryItem) (itemSummary, bool) {
	kind, ok := kindFromLibraryType(item.ItemType)
	if !ok {
		return itemSummary{}, false
	}
	if item.Collections == nil {
		item.Collections = []itemCollection{}
	}
	tags := []string{}
	_ = json.Unmarshal(item.Tags, &tags)
	return itemSummary{
		Excerpt: item.Excerpt, Waveform: item.Waveform, Collections: item.Collections,
		Ref: kind.name + ":" + item.ID, ID: item.ID, Type: kind.name, Title: item.Title,
		Status: item.Status, WordCount: item.WordCount, Favorite: item.Favorite,
		Archived: item.Archived, Tags: tags, CreatedAt: item.CreatedAt,
	}, true
}

func libraryTypeFlag(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	switch strings.ToLower(value) {
	case "video", "youtube", "transcript":
		return "youtube", nil
	case "audio":
		return "audio", nil
	case "pdf":
		return "pdf", nil
	}
	return "", fmt.Errorf("--type must be video, audio, or pdf")
}

// fetchLibrary pages through /library/items until limit (0 = everything).
func fetchLibrary(query url.Values, limit int) ([]itemSummary, error) {
	const pageSize = 100
	var items []itemSummary
	for page := 1; ; page++ {
		values := url.Values{}
		for key, list := range query {
			values[key] = list
		}
		values.Set("page", fmt.Sprint(page))
		values.Set("per_page", fmt.Sprint(pageSize))
		var response struct {
			Data       []libraryItem `json:"data"`
			TotalPages int           `json:"total_pages"`
		}
		if err := apiGetJSON("/library/items?"+values.Encode(), &response); err != nil {
			return nil, err
		}
		for _, raw := range response.Data {
			if summary, ok := summarizeLibraryItem(raw); ok {
				items = append(items, summary)
				if limit > 0 && len(items) >= limit {
					return items, nil
				}
			}
		}
		if page >= response.TotalPages || len(response.Data) == 0 {
			return items, nil
		}
	}
}

func printItemSummaries(stdout io.Writer, items []itemSummary, output string) error {
	if output == "json" {
		if items == nil {
			items = []itemSummary{}
		}
		return writeJSON(stdout, items)
	}
	if len(items) == 0 {
		fmt.Fprintln(stdout, "(no items)")
		return nil
	}
	for _, item := range items {
		fmt.Fprintf(stdout, "%s  %-10s  %s\n", item.Ref, item.Status, item.Title)
	}
	return nil
}

func itemsList(args []string, stdout, stderr io.Writer) error {
	flags := newFlags("items list", stderr)
	since := flags.String("since", "", "only items created at or after this date or RFC 3339 time")
	typ := flags.String("type", "", "video, audio, or pdf")
	status := flags.String("status", "", "active, pending, processing, completed, or failed")
	limit := flags.Int("limit", 0, "maximum items to return (0 = all)")
	archived := flags.Bool("archived", false, "include archived items")
	output := flags.String("output", "text", "text or json")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		return err
	}
	if len(positional) != 0 {
		return errors.New("usage: mta items list [flags]")
	}
	if err := checkOutput(*output); err != nil {
		return err
	}
	libType, err := libraryTypeFlag(*typ)
	if err != nil {
		return err
	}
	query := url.Values{}
	setIf(query, "type", libType)
	setIf(query, "status", *status)
	setIf(query, "since", *since)
	if *archived {
		query.Set("archive", "all")
	}
	items, err := fetchLibrary(query, *limit)
	if err != nil {
		return err
	}
	return printItemSummaries(stdout, items, *output)
}

func itemsSearch(args []string, stdout, stderr io.Writer) error {
	flags := newFlags("items search", stderr)
	typ := flags.String("type", "", "video, audio, or pdf")
	limit := flags.Int("limit", 50, "maximum items to return (0 = all)")
	output := flags.String("output", "text", "text or json")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		return err
	}
	if len(positional) == 0 {
		return errors.New("usage: mta items search <query> [flags]")
	}
	if err := checkOutput(*output); err != nil {
		return err
	}
	libType, err := libraryTypeFlag(*typ)
	if err != nil {
		return err
	}
	query := url.Values{}
	query.Set("search", strings.Join(positional, " "))
	setIf(query, "type", libType)
	items, err := fetchLibrary(query, *limit)
	if err != nil {
		return err
	}
	return printItemSummaries(stdout, items, *output)
}

func setIf(values url.Values, key, value string) {
	if value != "" {
		values.Set(key, value)
	}
}

// ── get ──

type itemChatMessage struct {
	Role      string `json:"role"`
	Content   string `json:"content"`
	CreatedAt string `json:"created_at,omitempty"`
}

type itemSummaryText struct {
	Text      string   `json:"text"`
	KeyPoints []string `json:"key_points,omitempty"`
}

// itemDetail is the stable JSON contract for `items get`.
type itemDetail struct {
	Ref        string            `json:"ref"`
	ID         string            `json:"id"`
	Type       string            `json:"type"`
	Title      string            `json:"title"`
	Status     string            `json:"status"`
	CreatedAt  string            `json:"created_at,omitempty"`
	WordCount  int               `json:"word_count"`
	Source     string            `json:"source,omitempty"`
	Favorite   bool              `json:"favorite"`
	Archived   bool              `json:"archived"`
	Tags       []string          `json:"tags"`
	Transcript string            `json:"transcript"`
	Summary    *itemSummaryText  `json:"summary,omitempty"`
	Chats      []itemChatMessage `json:"chats"`
}

func fetchItem(ref itemRef) (*itemDetail, error) {
	detail := &itemDetail{Ref: ref.String(), ID: ref.id, Type: ref.kind.name, Tags: []string{}, Chats: []itemChatMessage{}}
	base := ref.kind.path + ref.id

	switch ref.kind.name {
	case "video":
		var t struct {
			Title          string `json:"title"`
			ChannelName    string `json:"channel_name"`
			YouTubeURL     string `json:"youtube_url"`
			TranscriptText string `json:"transcript_text"`
			WordCount      int    `json:"word_count"`
			Status         string `json:"status"`
			CreatedAt      string `json:"created_at"`
		}
		if err := apiGetJSON(base, &t); err != nil {
			return nil, err
		}
		detail.Title, detail.Status, detail.CreatedAt = t.Title, t.Status, t.CreatedAt
		detail.WordCount, detail.Transcript, detail.Source = t.WordCount, t.TranscriptText, t.YouTubeURL
		var summaries []struct {
			SummaryText string          `json:"summary_text"`
			KeyPoints   json.RawMessage `json:"key_points"`
			Status      string          `json:"status"`
		}
		if err := apiGetJSON(base+"/summaries", &summaries); err != nil {
			return nil, err
		}
		for _, s := range summaries {
			if s.Status == "completed" && s.SummaryText != "" {
				detail.Summary = &itemSummaryText{Text: s.SummaryText, KeyPoints: flattenKeyPoints(s.KeyPoints)}
				break // the API lists newest first
			}
		}
	case "audio":
		var a struct {
			OriginalName        string          `json:"original_name"`
			TranscriptText      string          `json:"transcript_text"`
			FormattedTranscript string          `json:"formatted_transcript_text"`
			WordCount           int             `json:"word_count"`
			Status              string          `json:"status"`
			CreatedAt           string          `json:"created_at"`
			SummaryText         string          `json:"summary_text"`
			KeyPoints           json.RawMessage `json:"key_points"`
		}
		if err := apiGetJSON(base, &a); err != nil {
			return nil, err
		}
		detail.Title, detail.Status, detail.CreatedAt = a.OriginalName, a.Status, a.CreatedAt
		detail.WordCount, detail.Transcript = a.WordCount, a.TranscriptText
		if a.FormattedTranscript != "" {
			detail.Transcript = a.FormattedTranscript
		}
		if a.SummaryText != "" {
			detail.Summary = &itemSummaryText{Text: a.SummaryText, KeyPoints: flattenKeyPoints(a.KeyPoints)}
		}
	case "pdf":
		var p struct {
			OriginalName string `json:"original_name"`
			TextContent  string `json:"text_content"`
			WordCount    int    `json:"word_count"`
			Status       string `json:"status"`
			CreatedAt    string `json:"created_at"`
		}
		if err := apiGetJSON(base, &p); err != nil {
			return nil, err
		}
		detail.Title, detail.Status, detail.CreatedAt = p.OriginalName, p.Status, p.CreatedAt
		detail.WordCount, detail.Transcript = p.WordCount, p.TextContent
	}

	var chat struct {
		Messages []itemChatMessage `json:"messages"`
	}
	if err := apiGetJSON(base+"/chat", &chat); err != nil {
		// A transcript that is not ready has no chat yet; that is not an error
		// for reading the rest of the item.
		var statusErr apiStatusError
		if !errors.As(err, &statusErr) || statusErr.status != http.StatusConflict {
			return nil, err
		}
	} else if chat.Messages != nil {
		detail.Chats = chat.Messages
	}

	var prefs struct {
		Favorite bool            `json:"favorite"`
		Archived bool            `json:"archived"`
		Tags     json.RawMessage `json:"tags"`
	}
	if err := apiGetJSON("/library/items/"+ref.kind.prefType+"/"+ref.id+"/preferences", &prefs); err != nil {
		return nil, err
	}
	detail.Favorite, detail.Archived = prefs.Favorite, prefs.Archived
	_ = json.Unmarshal(prefs.Tags, &detail.Tags)
	if detail.Tags == nil {
		detail.Tags = []string{}
	}
	return detail, nil
}

// flattenKeyPoints accepts the shapes the API has used for key points: plain
// strings, or objects carrying the text under a common field.
func flattenKeyPoints(raw json.RawMessage) []string {
	var list []json.RawMessage
	if json.Unmarshal(raw, &list) != nil {
		return nil
	}
	var points []string
	for _, entry := range list {
		var text string
		if json.Unmarshal(entry, &text) == nil {
			if text != "" {
				points = append(points, text)
			}
			continue
		}
		var object map[string]interface{}
		if json.Unmarshal(entry, &object) == nil {
			for _, field := range []string{"text", "point", "content"} {
				if value, ok := object[field].(string); ok && value != "" {
					points = append(points, value)
					break
				}
			}
		}
	}
	return points
}

func itemsGet(args []string, stdout, stderr io.Writer) error {
	flags := newFlags("items get", stderr)
	format := flags.String("format", "md", "md or json")
	output := flags.String("output", "", "json is the same as --format json")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		return err
	}
	if len(positional) != 1 {
		return errors.New("usage: mta items get <type:id> [--format md|json]")
	}
	if *output == "json" {
		*format = "json"
	} else if *output != "" && *output != "text" {
		return errors.New("--output must be text or json")
	}
	if *format != "md" && *format != "json" {
		return errors.New("--format must be md or json")
	}
	ref, err := parseItemRef(positional[0])
	if err != nil {
		return err
	}
	detail, err := fetchItem(ref)
	if err != nil {
		return err
	}
	if *format == "json" {
		return writeJSON(stdout, detail)
	}
	_, err = io.WriteString(stdout, renderItemMarkdown(detail, false))
	return err
}

// ── mutations ──

type mutationResult struct {
	OK     bool   `json:"ok"`
	Action string `json:"action"`
	Ref    string `json:"ref"`
	Detail string `json:"detail,omitempty"`
}

func printMutation(stdout io.Writer, output string, result mutationResult) error {
	if output == "json" {
		return writeJSON(stdout, result)
	}
	line := result.Action + " " + result.Ref
	if result.Detail != "" {
		line += ": " + result.Detail
	}
	_, err := fmt.Fprintln(stdout, line)
	return err
}

// refAndOutput parses the common "<ref> [--output]" shape.
func refAndOutput(name string, args []string, stderr io.Writer, usage string, extra func(*flag.FlagSet)) (itemRef, string, []string, error) {
	flags := newFlags(name, stderr)
	output := flags.String("output", "text", "text or json")
	if extra != nil {
		extra(flags)
	}
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		return itemRef{}, "", nil, err
	}
	if len(positional) == 0 {
		return itemRef{}, "", nil, errors.New(usage)
	}
	if err := checkOutput(*output); err != nil {
		return itemRef{}, "", nil, err
	}
	ref, err := parseItemRef(positional[0])
	if err != nil {
		return itemRef{}, "", nil, err
	}
	return ref, *output, positional[1:], nil
}

func itemsRename(args []string, stdout, stderr io.Writer) error {
	ref, output, rest, err := refAndOutput("items rename", args, stderr, "usage: mta items rename <type:id> <name>", nil)
	if err != nil {
		return err
	}
	name := strings.TrimSpace(strings.Join(rest, " "))
	if name == "" {
		return errors.New("usage: mta items rename <type:id> <name>")
	}
	if ref.kind.name != "audio" {
		return fmt.Errorf("renaming is only available for audio items, not %s", ref.kind.name)
	}
	if _, err := apiCall(http.MethodPatch, ref.kind.path+ref.id, map[string]string{"name": name}); err != nil {
		return err
	}
	return printMutation(stdout, output, mutationResult{OK: true, Action: "renamed", Ref: ref.String()})
}

// updatePreferences applies a change to tags, favorite, or archived.
func updatePreferences(ref itemRef, payload map[string]interface{}) error {
	_, err := apiCall(http.MethodPatch, "/library/items/"+ref.kind.prefType+"/"+ref.id+"/preferences", payload)
	return err
}

func currentTags(ref itemRef) ([]string, error) {
	var prefs struct {
		Tags []string `json:"tags"`
	}
	if err := apiGetJSON("/library/items/"+ref.kind.prefType+"/"+ref.id+"/preferences", &prefs); err != nil {
		return nil, err
	}
	return prefs.Tags, nil
}

func splitList(value string) []string {
	var out []string
	for _, part := range strings.Split(value, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}

func itemsTag(args []string, stdout, stderr io.Writer) error {
	var add, remove, set *string
	var clear *bool
	ref, output, rest, err := refAndOutput("items tag", args, stderr, "usage: mta items tag <type:id> [--add a,b] [--remove c] [--set a,b] [--clear]", func(flags *flag.FlagSet) {
		add = flags.String("add", "", "comma-separated tags to add")
		remove = flags.String("remove", "", "comma-separated tags to remove")
		set = flags.String("set", "", "replace all tags with these")
		clear = flags.Bool("clear", false, "remove every tag")
	})
	if err != nil {
		return err
	}
	if len(rest) != 0 {
		return errors.New("usage: mta items tag <type:id> [--add a,b] [--remove c] [--set a,b]")
	}
	if *add == "" && *remove == "" && *set == "" && !*clear {
		return errors.New("give --add, --remove, --set, or --clear")
	}
	var tags []string
	if *clear {
		tags = nil
	} else if *set != "" {
		tags = splitList(*set)
	} else {
		if tags, err = currentTags(ref); err != nil {
			return err
		}
	}
	removed := map[string]bool{}
	for _, tag := range splitList(*remove) {
		removed[strings.ToLower(tag)] = true
	}
	merged := []string{}
	seen := map[string]bool{}
	for _, tag := range append(tags, splitList(*add)...) {
		key := strings.ToLower(tag)
		if removed[key] || seen[key] {
			continue
		}
		seen[key] = true
		merged = append(merged, tag)
	}
	if err := updatePreferences(ref, map[string]interface{}{"tags": merged}); err != nil {
		return err
	}
	return printMutation(stdout, output, mutationResult{OK: true, Action: "tagged", Ref: ref.String(), Detail: strings.Join(merged, ", ")})
}

func itemsToggle(args []string, stdout, stderr io.Writer, field string) error {
	var off *bool
	ref, output, rest, err := refAndOutput("items "+field, args, stderr, "usage: mta items favorite|archive <type:id> [--off]", func(flags *flag.FlagSet) {
		off = flags.Bool("off", false, "turn it off instead of on")
	})
	if err != nil {
		return err
	}
	if len(rest) != 0 {
		return errors.New("usage: mta items favorite|archive <type:id> [--off]")
	}
	if err := updatePreferences(ref, map[string]interface{}{field: !*off}); err != nil {
		return err
	}
	action := map[string]string{"favorite": "favorited", "archived": "archived"}[field]
	if *off {
		action = "un" + action
	}
	return printMutation(stdout, output, mutationResult{OK: true, Action: action, Ref: ref.String()})
}

type collectionSummary struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// resolveCollection finds a collection by full id or exact (case-insensitive)
// name. A missing name is created when create is set, so a filing agent can
// say "Brain Dump" without a separate setup step.
func resolveCollection(nameOrID string, create bool) (collectionSummary, error) {
	var collections []collectionSummary
	if err := apiGetJSON("/collections", &collections); err != nil {
		return collectionSummary{}, err
	}
	var matches []collectionSummary
	for _, collection := range collections {
		if collection.ID == nameOrID {
			return collection, nil
		}
		if strings.EqualFold(collection.Name, nameOrID) {
			matches = append(matches, collection)
		}
	}
	if len(matches) > 1 {
		return collectionSummary{}, fmt.Errorf("%d collections are named %q; use the collection id", len(matches), nameOrID)
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	if !create || looksLikeUUID(nameOrID) {
		return collectionSummary{}, fmt.Errorf("no collection named %q", nameOrID)
	}
	data, err := apiCall(http.MethodPost, "/collections", map[string]string{"name": nameOrID})
	if err != nil {
		return collectionSummary{}, err
	}
	var created collectionSummary
	if err := json.Unmarshal(data, &created); err != nil || created.ID == "" {
		return collectionSummary{}, errors.New("unexpected response creating collection")
	}
	return created, nil
}

func itemsCollection(args []string, stdout, stderr io.Writer) error {
	var add, remove *string
	ref, output, rest, err := refAndOutput("items collection", args, stderr, "usage: mta items collection <type:id> (--add NAME|ID | --remove NAME|ID)", func(flags *flag.FlagSet) {
		add = flags.String("add", "", "collection name or id to file the item in (created if the name is new)")
		remove = flags.String("remove", "", "collection name or id to take the item out of")
	})
	if err != nil {
		return err
	}
	if len(rest) != 0 || (*add == "") == (*remove == "") {
		return errors.New("usage: mta items collection <type:id> (--add NAME|ID | --remove NAME|ID)")
	}
	if *add != "" {
		collection, err := resolveCollection(*add, true)
		if err != nil {
			return err
		}
		_, err = apiCall(http.MethodPost, "/collections/"+collection.ID+"/items", map[string]interface{}{
			"items": []map[string]string{{"item_type": ref.kind.colType, "item_id": ref.id}},
		})
		if err != nil {
			return err
		}
		return printMutation(stdout, output, mutationResult{OK: true, Action: "filed", Ref: ref.String(), Detail: collection.Name + " (" + collection.ID + ")"})
	}
	collection, err := resolveCollection(*remove, false)
	if err != nil {
		return err
	}
	var detail struct {
		Items []struct {
			ID       string `json:"id"`
			ItemType string `json:"item_type"`
			ItemID   string `json:"item_id"`
		} `json:"items"`
	}
	if err := apiGetJSON("/collections/"+collection.ID, &detail); err != nil {
		return err
	}
	for _, entry := range detail.Items {
		if entry.ItemType == ref.kind.colType && strings.EqualFold(entry.ItemID, ref.id) {
			if _, err := apiCall(http.MethodDelete, "/collections/"+collection.ID+"/items/"+entry.ID, nil); err != nil {
				return err
			}
			return printMutation(stdout, output, mutationResult{OK: true, Action: "removed", Ref: ref.String(), Detail: collection.Name + " (" + collection.ID + ")"})
		}
	}
	return fmt.Errorf("%s is not in %q", ref, collection.Name)
}

func itemsRetry(args []string, stdout, stderr io.Writer) error {
	ref, output, rest, err := refAndOutput("items retry", args, stderr, "usage: mta items retry <type:id>", nil)
	if err != nil {
		return err
	}
	if len(rest) != 0 {
		return errors.New("usage: mta items retry <type:id>")
	}
	if ref.kind.name != "audio" {
		return fmt.Errorf("retry is only available for audio items, not %s", ref.kind.name)
	}
	if _, err := apiCall(http.MethodPost, ref.kind.path+ref.id+"/retry", map[string]string{}); err != nil {
		return err
	}
	return printMutation(stdout, output, mutationResult{OK: true, Action: "retry queued", Ref: ref.String()})
}

func itemsSummarize(args []string, stdout, stderr io.Writer) error {
	var length *string
	ref, output, rest, err := refAndOutput("items summarize", args, stderr, "usage: mta items summarize <type:id> [--length short|medium|detailed]", func(flags *flag.FlagSet) {
		length = flags.String("length", "medium", "short, medium, or detailed")
	})
	if err != nil {
		return err
	}
	if len(rest) != 0 {
		return errors.New("usage: mta items summarize <type:id> [--length short|medium|detailed]")
	}
	switch ref.kind.name {
	case "audio":
		_, err = apiCall(http.MethodPost, ref.kind.path+ref.id+"/summarize", map[string]string{"length": *length})
	case "video":
		_, err = apiCall(http.MethodPost, "/summaries", map[string]string{"transcript_id": ref.id, "length": *length})
	default:
		return fmt.Errorf("summaries are not available for %s items", ref.kind.name)
	}
	if err != nil {
		return err
	}
	return printMutation(stdout, output, mutationResult{OK: true, Action: "summary queued", Ref: ref.String()})
}

func itemsChat(args []string, stdout, stderr io.Writer) error {
	ref, output, rest, err := refAndOutput("items chat", args, stderr, "usage: mta items chat <type:id> <message>", nil)
	if err != nil {
		return err
	}
	message := strings.TrimSpace(strings.Join(rest, " "))
	if message == "" {
		return errors.New("usage: mta items chat <type:id> <message>")
	}
	data, err := apiCall(http.MethodPost, ref.kind.path+ref.id+"/chat", map[string]string{"message": message})
	if err != nil {
		return err
	}
	var response struct {
		Messages []itemChatMessage `json:"messages"`
	}
	if err := json.Unmarshal(data, &response); err != nil {
		return fmt.Errorf("unexpected chat response: %w", err)
	}
	reply := ""
	for _, msg := range response.Messages {
		if msg.Role == "assistant" {
			reply = msg.Content
		}
	}
	if output == "json" {
		return writeJSON(stdout, map[string]interface{}{"ok": true, "ref": ref.String(), "reply": reply})
	}
	_, err = fmt.Fprintln(stdout, reply)
	return err
}

func itemsDelete(args []string, stdout, stderr io.Writer) error {
	var yes *bool
	ref, output, rest, err := refAndOutput("items delete", args, stderr, "usage: mta items delete <type:id> --yes", func(flags *flag.FlagSet) {
		yes = flags.Bool("yes", false, "confirm permanent deletion")
	})
	if err != nil {
		return err
	}
	if len(rest) != 0 {
		return errors.New("usage: mta items delete <type:id> --yes")
	}
	if !*yes {
		return fmt.Errorf("deleting %s is permanent; repeat with --yes to confirm", ref)
	}
	if _, err := apiCall(http.MethodDelete, ref.kind.path+ref.id, nil); err != nil {
		return err
	}
	return printMutation(stdout, output, mutationResult{OK: true, Action: "deleted", Ref: ref.String()})
}
