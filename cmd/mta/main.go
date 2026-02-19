// mta is the Media Tools API command-line client.
// It allows agents and users to transcribe videos, manage collections,
// search the library, and chat with AI — all from the terminal.
//
// Usage:
//
//	mta transcribe <url>              Submit a video for transcription
//	mta status <id>                   Check transcript status
//	mta get <id>                      Get full transcript text
//	mta list [--type video|audio|pdf] List library items
//	mta search <query>                Search transcripts by title
//	mta collections                   List collections
//	mta collection <id>               Show collection detail
//	mta collection create <name>      Create a new collection
//	mta collect <item-id> <col-id>    Add item to collection
//	mta chat <id> <message>           Chat about a transcript
//	mta chat-collection <id> <msg>    Chat about a collection
//	mta summary <id>                  Get/create summary for transcript
//
// Configuration:
//
//	MTA_API_KEY    API key (required)
//	MTA_API_URL    API base URL (default: https://media-tools-api.onrender.com)
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

var (
	apiKey  string
	apiBase string
	client  = &http.Client{Timeout: 60 * time.Second}
)

func init() {
	apiKey = os.Getenv("MTA_API_KEY")
	apiBase = os.Getenv("MTA_API_URL")
	if apiBase == "" {
		apiBase = "https://media-tools-api.onrender.com"
	}
	apiBase = strings.TrimRight(apiBase, "/") + "/api/v1"
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}
	if apiKey == "" {
		fmt.Fprintln(os.Stderr, "Error: MTA_API_KEY not set. Export your API key first.")
		os.Exit(1)
	}

	cmd := os.Args[1]
	args := os.Args[2:]

	var err error
	switch cmd {
	case "transcribe":
		err = cmdTranscribe(args)
	case "status":
		err = cmdStatus(args)
	case "get":
		err = cmdGet(args)
	case "list":
		err = cmdList(args)
	case "search":
		err = cmdSearch(args)
	case "collections":
		err = cmdCollections()
	case "collection":
		err = cmdCollection(args)
	case "collect":
		err = cmdCollect(args)
	case "summary":
		err = cmdSummary(args)
	case "chat":
		err = cmdChat(args)
	case "chat-collection":
		err = cmdChatCollection(args)
	case "health":
		err = cmdHealth()
	case "help", "-h", "--help":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", cmd)
		printUsage()
		os.Exit(1)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Println(`mta — Media Tools API CLI

Commands:
  transcribe <url>              Submit video URL for transcription (waits for completion)
  status <id>                   Check transcript status
  get <id>                      Print full transcript text
  list [--type video|audio|pdf] List library items
  search <query>                Search by title
  collections                   List all collections
  collection <id>               Show collection with items
  collection create <name>      Create a new collection
  collect <item-id> <col-id>    Add an item to a collection
  summary <id> [--type tutorial|lecture|podcast|conference|review]
                                Generate AI summary for a transcript
  chat <id> <message>           Chat about a transcript/audio/pdf
  chat-collection <id> <msg>    Chat about all items in a collection
  health                        Check API health

Environment:
  MTA_API_KEY    Your API key (required)
  MTA_API_URL    API base URL (default: production Render)`)
}

// ── HTTP helpers ──

func doGet(path string) ([]byte, error) {
	req, err := http.NewRequest("GET", apiBase+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-API-Key", apiKey)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(body))
	}
	return body, nil
}

func doPost(path string, payload interface{}) ([]byte, error) {
	jsonBody, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest("POST", apiBase+path, bytes.NewReader(jsonBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-API-Key", apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(body))
	}
	return body, nil
}

func doDelete(path string) error {
	req, err := http.NewRequest("DELETE", apiBase+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("X-API-Key", apiKey)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(body))
	}
	return nil
}

func prettyJSON(data []byte) string {
	var buf bytes.Buffer
	json.Indent(&buf, data, "", "  ")
	return buf.String()
}

// ── Commands ──

func cmdHealth() error {
	body, err := doGet("/health")
	if err != nil {
		return err
	}
	fmt.Println(prettyJSON(body))
	return nil
}

func cmdTranscribe(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: mta transcribe <url>")
	}
	videoURL := args[0]

	// Submit
	body, err := doPost("/transcripts", map[string]string{"url": videoURL})
	if err != nil {
		return fmt.Errorf("submit failed: %w", err)
	}

	var result struct {
		ID     string `json:"id"`
		Status string `json:"status"`
		Title  string `json:"title"`
	}
	json.Unmarshal(body, &result)
	fmt.Printf("Submitted: %s (status: %s)\n", result.ID, result.Status)

	// Poll for completion
	fmt.Print("Waiting for transcription")
	for i := 0; i < 30; i++ {
		time.Sleep(5 * time.Second)
		fmt.Print(".")

		statusBody, err := doGet("/transcripts/" + result.ID)
		if err != nil {
			continue
		}
		json.Unmarshal(statusBody, &result)
		if result.Status == "completed" {
			fmt.Printf("\n✅ Complete: %s\n", result.Title)
			fmt.Printf("   ID: %s\n", result.ID)

			// Get word count
			var full struct {
				WordCount int `json:"word_count"`
			}
			json.Unmarshal(statusBody, &full)
			fmt.Printf("   Words: %d\n", full.WordCount)
			return nil
		}
		if result.Status == "failed" {
			var errResult struct {
				ErrorMessage string `json:"error_message"`
			}
			json.Unmarshal(statusBody, &errResult)
			return fmt.Errorf("transcription failed: %s", errResult.ErrorMessage)
		}
	}
	return fmt.Errorf("timed out waiting for transcription (ID: %s)", result.ID)
}

func cmdStatus(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: mta status <id>")
	}
	body, err := doGet("/transcripts/" + args[0])
	if err != nil {
		return err
	}
	var result struct {
		ID        string `json:"id"`
		Status    string `json:"status"`
		Title     string `json:"title"`
		WordCount int    `json:"word_count"`
	}
	json.Unmarshal(body, &result)
	fmt.Printf("ID:     %s\nStatus: %s\nTitle:  %s\nWords:  %d\n", result.ID, result.Status, result.Title, result.WordCount)
	return nil
}

func cmdGet(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: mta get <id>")
	}
	body, err := doGet("/transcripts/" + args[0])
	if err != nil {
		return err
	}
	var result struct {
		Title          string `json:"title"`
		TranscriptText string `json:"transcript_text"`
	}
	json.Unmarshal(body, &result)
	if result.Title != "" {
		fmt.Printf("# %s\n\n", result.Title)
	}
	fmt.Println(result.TranscriptText)
	return nil
}

func cmdList(args []string) error {
	// Parse --type flag
	contentType := ""
	for i, arg := range args {
		if arg == "--type" && i+1 < len(args) {
			contentType = args[i+1]
		}
	}

	if contentType == "" || contentType == "video" {
		fmt.Println("── Video Transcripts ──")
		body, err := doGet("/transcripts")
		if err != nil {
			fmt.Printf("  (error: %v)\n", err)
		} else {
			var resp struct {
				Data []struct {
					ID        string `json:"id"`
					Title     string `json:"title"`
					Status    string `json:"status"`
					WordCount int    `json:"word_count"`
					CreatedAt string `json:"created_at"`
				} `json:"data"`
			}
			json.Unmarshal(body, &resp)
			if len(resp.Data) == 0 {
				fmt.Println("  (none)")
			}
			for _, t := range resp.Data {
				title := t.Title
				if title == "" {
					title = "(untitled)"
				}
				fmt.Printf("  %s  %-50s  %s  %d words\n", t.ID[:8], truncate(title, 50), t.Status, t.WordCount)
			}
		}
	}

	if contentType == "" || contentType == "audio" {
		fmt.Println("\n── Audio Transcriptions ──")
		body, err := doGet("/audio/transcriptions")
		if err != nil {
			fmt.Printf("  (error: %v)\n", err)
		} else {
			var items []struct {
				ID        string `json:"id"`
				Title     string `json:"title"`
				Status    string `json:"status"`
				CreatedAt string `json:"created_at"`
			}
			json.Unmarshal(body, &items)
			if len(items) == 0 {
				fmt.Println("  (none)")
			}
			for _, a := range items {
				title := a.Title
				if title == "" {
					title = "(untitled)"
				}
				fmt.Printf("  %s  %-50s  %s\n", a.ID[:8], truncate(title, 50), a.Status)
			}
		}
	}

	if contentType == "" || contentType == "pdf" {
		fmt.Println("\n── PDF Extractions ──")
		body, err := doGet("/pdf/extractions")
		if err != nil {
			fmt.Printf("  (error: %v)\n", err)
		} else {
			var items []struct {
				ID       string `json:"id"`
				Filename string `json:"filename"`
				Status   string `json:"status"`
			}
			json.Unmarshal(body, &items)
			if len(items) == 0 {
				fmt.Println("  (none)")
			}
			for _, p := range items {
				name := p.Filename
				if name == "" {
					name = "(untitled)"
				}
				fmt.Printf("  %s  %-50s  %s\n", p.ID[:8], truncate(name, 50), p.Status)
			}
		}
	}

	return nil
}

func cmdSearch(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: mta search <query>")
	}
	query := strings.Join(args, " ")
	body, err := doGet("/transcripts?search=" + url.QueryEscape(query))
	if err != nil {
		return err
	}
	var resp struct {
		Data []struct {
			ID        string `json:"id"`
			Title     string `json:"title"`
			Status    string `json:"status"`
			WordCount int    `json:"word_count"`
		} `json:"data"`
		Total int `json:"total"`
	}
	json.Unmarshal(body, &resp)
	fmt.Printf("Found %d results for \"%s\":\n\n", resp.Total, query)
	for _, t := range resp.Data {
		fmt.Printf("  %s  %-50s  %d words\n", t.ID[:8], truncate(t.Title, 50), t.WordCount)
	}
	return nil
}

func cmdCollections() error {
	body, err := doGet("/collections")
	if err != nil {
		return err
	}
	var collections []struct {
		ID          string `json:"id"`
		Name        string `json:"name"`
		Description string `json:"description"`
		ItemCount   int    `json:"item_count"`
	}
	json.Unmarshal(body, &collections)
	if len(collections) == 0 {
		fmt.Println("No collections yet. Create one with: mta collection create <name>")
		return nil
	}
	fmt.Println("Collections:")
	for _, c := range collections {
		desc := ""
		if c.Description != "" {
			desc = " — " + truncate(c.Description, 40)
		}
		fmt.Printf("  %s  %-30s  %d items%s\n", c.ID[:8], c.Name, c.ItemCount, desc)
	}
	return nil
}

func cmdCollection(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: mta collection <id> | mta collection create <name>")
	}

	// Handle "collection create <name>"
	if args[0] == "create" {
		if len(args) < 2 {
			return fmt.Errorf("usage: mta collection create <name> [description]")
		}
		name := args[1]
		desc := ""
		if len(args) > 2 {
			desc = strings.Join(args[2:], " ")
		}
		body, err := doPost("/collections", map[string]string{"name": name, "description": desc})
		if err != nil {
			return err
		}
		var col struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		}
		json.Unmarshal(body, &col)
		fmt.Printf("✅ Created collection: %s (%s)\n", col.Name, col.ID)
		return nil
	}

	// Show collection detail
	body, err := doGet("/collections/" + args[0])
	if err != nil {
		return err
	}
	var col struct {
		ID          string `json:"id"`
		Name        string `json:"name"`
		Description string `json:"description"`
		Items       []struct {
			ID         string `json:"id"`
			ItemType   string `json:"item_type"`
			ItemID     string `json:"item_id"`
			ItemTitle  string `json:"item_title"`
			ItemStatus string `json:"item_status"`
		} `json:"items"`
	}
	json.Unmarshal(body, &col)
	fmt.Printf("Collection: %s\n", col.Name)
	if col.Description != "" {
		fmt.Printf("  %s\n", col.Description)
	}
	fmt.Printf("  ID: %s\n\n", col.ID)
	if len(col.Items) == 0 {
		fmt.Println("  (no items)")
	} else {
		for _, item := range col.Items {
			title := item.ItemTitle
			if title == "" {
				title = item.ItemID[:8]
			}
			fmt.Printf("  [%s] %s (%s)\n", item.ItemType, title, item.ItemStatus)
		}
	}
	return nil
}

func cmdCollect(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: mta collect <item-id> <collection-id> [--type transcript|audio|pdf]")
	}
	itemID := args[0]
	colID := args[1]
	itemType := "transcript" // default
	for i, arg := range args {
		if arg == "--type" && i+1 < len(args) {
			itemType = args[i+1]
		}
	}

	body, err := doPost("/collections/"+colID+"/items", map[string]interface{}{
		"items": []map[string]string{{"item_type": itemType, "item_id": itemID}},
	})
	if err != nil {
		return err
	}
	var result struct {
		Added int `json:"added"`
	}
	json.Unmarshal(body, &result)
	fmt.Printf("✅ Added %d item(s) to collection\n", result.Added)
	return nil
}

func cmdSummary(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: mta summary <transcript-id> [--type tutorial|lecture|podcast|conference|review] [--length short|medium|detailed]")
	}
	id := args[0]
	contentType := ""
	length := "medium"
	style := "bullet"
	for i, arg := range args {
		if arg == "--type" && i+1 < len(args) {
			contentType = args[i+1]
		}
		if arg == "--length" && i+1 < len(args) {
			length = args[i+1]
		}
		if arg == "--style" && i+1 < len(args) {
			style = args[i+1]
		}
	}

	payload := map[string]string{
		"transcript_id": id,
		"length":        length,
		"style":         style,
	}
	if contentType != "" {
		payload["content_type"] = contentType
	}

	fmt.Println("Generating summary...")
	body, err := doPost("/summaries", payload)
	if err != nil {
		return fmt.Errorf("summary request failed: %w", err)
	}

	// The summary is async — check if we got a 202 or a direct result
	var accepted struct {
		Message string `json:"message"`
	}
	json.Unmarshal(body, &accepted)
	if accepted.Message != "" {
		fmt.Printf("⏳ %s\n", accepted.Message)
		fmt.Println("Summary is generating in the background. Check with: mta status <id>")
		return nil
	}

	// If we got a direct summary (synchronous path)
	fmt.Println(prettyJSON(body))
	return nil
}

func cmdChat(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: mta chat <transcript-id> <message>")
	}
	id := args[0]
	message := strings.Join(args[1:], " ")

	body, err := doPost("/transcripts/"+id+"/chat", map[string]string{"message": message})
	if err != nil {
		return err
	}
	var resp struct {
		Messages []struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"messages"`
	}
	json.Unmarshal(body, &resp)
	for _, msg := range resp.Messages {
		if msg.Role == "assistant" {
			fmt.Println(msg.Content)
		}
	}
	return nil
}

func cmdChatCollection(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: mta chat-collection <collection-id> <message>")
	}
	id := args[0]
	message := strings.Join(args[1:], " ")

	body, err := doPost("/collections/"+id+"/chat", map[string]string{"message": message})
	if err != nil {
		return err
	}
	var resp struct {
		Messages []struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"messages"`
	}
	json.Unmarshal(body, &resp)
	for _, msg := range resp.Messages {
		if msg.Role == "assistant" {
			fmt.Println(msg.Content)
		}
	}
	return nil
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-1] + "…"
}
