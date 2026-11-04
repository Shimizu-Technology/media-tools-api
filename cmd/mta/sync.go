package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// renderItemMarkdown turns an item into a Markdown note. With frontmatter it
// is the sync format, keyed by media_tools_id so a rerun updates in place.
//
// Transcript text is untrusted data. It is written below a heading and never
// interpreted; anything reading these notes must treat it the same way.
func renderItemMarkdown(item *itemDetail, frontmatter bool) string {
	var b strings.Builder
	if frontmatter {
		b.WriteString("---\n")
		fmt.Fprintf(&b, "media_tools_id: %s\n", yamlString(item.Ref))
		fmt.Fprintf(&b, "title: %s\n", yamlString(item.Title))
		fmt.Fprintf(&b, "type: %s\n", item.Type)
		fmt.Fprintf(&b, "status: %s\n", item.Status)
		if item.CreatedAt != "" {
			fmt.Fprintf(&b, "created: %s\n", yamlString(item.CreatedAt))
		}
		tags, _ := json.Marshal(item.Tags)
		fmt.Fprintf(&b, "tags: %s\n", tags)
		fmt.Fprintf(&b, "favorite: %t\n", item.Favorite)
		if item.Source != "" {
			fmt.Fprintf(&b, "source: %s\n", yamlString(item.Source))
		}
		b.WriteString("---\n\n")
	}
	title := item.Title
	if title == "" {
		title = "Untitled"
	}
	fmt.Fprintf(&b, "# %s\n\n", title)
	if !frontmatter {
		fmt.Fprintf(&b, "- ref: %s\n- status: %s\n", item.Ref, item.Status)
		if item.CreatedAt != "" {
			fmt.Fprintf(&b, "- created: %s\n", item.CreatedAt)
		}
		if len(item.Tags) > 0 {
			fmt.Fprintf(&b, "- tags: %s\n", strings.Join(item.Tags, ", "))
		}
		b.WriteString("\n")
	}
	if item.Summary != nil {
		b.WriteString("## Summary\n\n")
		b.WriteString(strings.TrimSpace(item.Summary.Text))
		b.WriteString("\n\n")
		if len(item.Summary.KeyPoints) > 0 {
			b.WriteString("### Key points\n\n")
			for _, point := range item.Summary.KeyPoints {
				fmt.Fprintf(&b, "- %s\n", point)
			}
			b.WriteString("\n")
		}
	}
	b.WriteString("## Transcript\n\n")
	b.WriteString(strings.TrimSpace(item.Transcript))
	b.WriteString("\n")
	if !frontmatter && len(item.Chats) > 0 {
		b.WriteString("\n## Chat history\n\n")
		for _, msg := range item.Chats {
			fmt.Fprintf(&b, "**%s:** %s\n\n", msg.Role, strings.TrimSpace(msg.Content))
		}
	}
	return b.String()
}

// yamlString quotes a value as a JSON string, which is valid YAML.
func yamlString(value string) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}

func slugify(title string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(title) {
		switch {
		case r >= 'a' && r <= 'z' || r >= '0' && r <= '9':
			b.WriteRune(r)
			dash = false
		case !dash && b.Len() > 0:
			b.WriteByte('-')
			dash = true
		}
		if b.Len() >= 60 {
			break
		}
	}
	slug := strings.Trim(b.String(), "-")
	if slug == "" {
		slug = "untitled"
	}
	return slug
}

// indexNotes maps media_tools_id values to the notes that already carry them.
func indexNotes(dir string) (map[string]string, error) {
	notes := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || !strings.EqualFold(filepath.Ext(path), ".md") {
			return nil
		}
		if id := readNoteID(path); id != "" {
			if _, exists := notes[id]; !exists {
				notes[id] = path
			}
		}
		return nil
	})
	return notes, err
}

func readNoteID(path string) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	if !scanner.Scan() || strings.TrimSpace(scanner.Text()) != "---" {
		return ""
	}
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "---" {
			return ""
		}
		if value, ok := strings.CutPrefix(line, "media_tools_id:"); ok {
			value = strings.TrimSpace(value)
			value = strings.Trim(value, `"'`)
			return value
		}
	}
	return ""
}

func writeFileAtomic(path string, content []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".mta-sync-*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err := temp.Write(content); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tempPath, 0o644); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}

type syncEntry struct {
	Ref    string `json:"ref"`
	Path   string `json:"path,omitempty"`
	Action string `json:"action"`
	Error  string `json:"error,omitempty"`
}

type syncResult struct {
	Dir       string      `json:"dir"`
	Created   int         `json:"created"`
	Updated   int         `json:"updated"`
	Unchanged int         `json:"unchanged"`
	Failed    int         `json:"failed"`
	Entries   []syncEntry `json:"entries"`
}

func cmdSync(args []string) error { return runSync(args, os.Stdout, os.Stderr) }

func runSync(args []string, stdout, stderr io.Writer) error {
	flags := newFlags("sync", stderr)
	dir := flags.String("dir", "", "directory to write Markdown notes into (required)")
	collection := flags.String("collection", "", "only items filed in this collection (name or id)")
	all := flags.Bool("all", false, "sync every completed library item")
	since := flags.String("since", "", "only items created at or after this date or RFC 3339 time")
	output := flags.String("output", "text", "text or json")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		return err
	}
	if len(positional) != 0 {
		return errors.New("usage: mta sync --dir <path> (--collection NAME | --all) [--since DATE]")
	}
	if err := checkOutput(*output); err != nil {
		return err
	}
	if apiKey == "" {
		return errors.New("MTA_API_KEY is required")
	}
	if *dir == "" {
		return errors.New("--dir is required")
	}
	if *collection == "" && !*all {
		// Filing is a deliberate act. Writing the whole library to disk must be too.
		return errors.New("choose what to sync: --collection NAME for one collection, or --all for the whole library")
	}

	query := url.Values{"status": {"completed"}}
	setIf(query, "since", *since)
	items, err := fetchLibrary(query, 0)
	if err != nil {
		return err
	}
	if *collection != "" {
		resolved, err := resolveCollection(*collection, false)
		if err != nil {
			return err
		}
		var detail struct {
			Items []struct {
				ItemType string `json:"item_type"`
				ItemID   string `json:"item_id"`
			} `json:"items"`
		}
		if err := apiGetJSON("/collections/"+resolved.ID, &detail); err != nil {
			return err
		}
		members := map[string]bool{}
		for _, entry := range detail.Items {
			members[strings.ToLower(entry.ItemID)] = true
		}
		filtered := items[:0]
		for _, item := range items {
			if members[strings.ToLower(item.ID)] {
				filtered = append(filtered, item)
			}
		}
		items = filtered
	}

	if err := os.MkdirAll(*dir, 0o755); err != nil {
		return err
	}
	existing, err := indexNotes(*dir)
	if err != nil {
		return fmt.Errorf("scan %s: %w", *dir, err)
	}

	result := syncResult{Dir: *dir, Entries: []syncEntry{}}
	for _, summary := range items {
		ref, err := parseItemRef(summary.Ref)
		if err != nil {
			continue
		}
		entry := syncEntry{Ref: summary.Ref}
		detail, err := fetchItem(ref)
		if err != nil {
			entry.Action, entry.Error = "failed", err.Error()
			result.Failed++
			result.Entries = append(result.Entries, entry)
			continue
		}
		content := []byte(renderItemMarkdown(detail, true))
		path, found := existing[summary.Ref]
		if !found {
			// The full type and id keep two items from sharing a path. A file already
			// here is someone else's note, because ours would have matched by frontmatter.
			path = filepath.Join(*dir, slugify(detail.Title)+"-"+ref.kind.name+"-"+ref.id+".md")
			if _, statErr := os.Stat(path); statErr == nil {
				entry.Path = path
				entry.Action, entry.Error = "failed", "a different note already exists at this path"
				result.Failed++
				result.Entries = append(result.Entries, entry)
				continue
			}
		}
		entry.Path = path
		if previous, readErr := os.ReadFile(path); readErr == nil && string(previous) == string(content) {
			entry.Action = "unchanged"
			result.Unchanged++
		} else if err := writeFileAtomic(path, content); err != nil {
			entry.Action, entry.Error = "failed", err.Error()
			result.Failed++
		} else if found {
			entry.Action = "updated"
			result.Updated++
		} else {
			entry.Action = "created"
			result.Created++
		}
		result.Entries = append(result.Entries, entry)
	}
	sort.Slice(result.Entries, func(i, j int) bool { return result.Entries[i].Ref < result.Entries[j].Ref })

	if *output == "json" {
		if err := writeJSON(stdout, result); err != nil {
			return err
		}
	} else {
		fmt.Fprintf(stdout, "Synced to %s: %d created, %d updated, %d unchanged, %d failed\n",
			result.Dir, result.Created, result.Updated, result.Unchanged, result.Failed)
		for _, entry := range result.Entries {
			if entry.Action == "failed" {
				fmt.Fprintf(stdout, "  failed %s: %s\n", entry.Ref, entry.Error)
			}
		}
	}
	if result.Failed > 0 {
		return fmt.Errorf("%d item(s) failed to sync", result.Failed)
	}
	return nil
}
