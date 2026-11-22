package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

type collectionListEntry struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Color       string `json:"color,omitempty"`
	ItemCount   int    `json:"item_count"`
}

type collectionMemberItem struct {
	ID     string `json:"id"`
	Ref    string `json:"ref"`
	Type   string `json:"type"`
	ItemID string `json:"item_id"`
	Title  string `json:"title"`
	Status string `json:"status"`
}

type collectionDetailView struct {
	ID          string                 `json:"id"`
	Name        string                 `json:"name"`
	Description string                 `json:"description,omitempty"`
	Color       string                 `json:"color,omitempty"`
	Items       []collectionMemberItem `json:"items"`
}

func cmdCollections(args []string) error { return runCollections(args, os.Stdout, os.Stderr) }
func cmdCollection(args []string) error  { return runCollection(args, os.Stdout, os.Stderr) }
func cmdChatCollection(args []string) error {
	return runChatCollection(args, os.Stdout, os.Stderr)
}

func runCollections(args []string, stdout, stderr io.Writer) error {
	flags := newFlags("collections", stderr)
	output := flags.String("output", "text", "text or json")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if len(positional) != 0 {
		return errors.New("usage: mta collections [--output text|json]")
	}
	if err := checkOutput(*output); err != nil {
		return err
	}
	if apiKey == "" {
		return errors.New("MTA_API_KEY is required")
	}

	var collections []collectionListEntry
	if err := apiGetJSON("/collections", &collections); err != nil {
		return err
	}
	if collections == nil {
		collections = []collectionListEntry{}
	}
	if *output == "json" {
		return writeJSON(stdout, collections)
	}
	if len(collections) == 0 {
		_, err := fmt.Fprintln(stdout, "No collections yet. Create one with: mta collection create <name>")
		return err
	}
	if _, err := fmt.Fprintln(stdout, "Collections:"); err != nil {
		return err
	}
	for _, c := range collections {
		desc := ""
		if c.Description != "" {
			desc = " — " + truncate(c.Description, 40)
		}
		if _, err := fmt.Fprintf(stdout, "  %s  %-30s  %d items%s\n", c.ID, c.Name, c.ItemCount, desc); err != nil {
			return err
		}
	}
	return nil
}

func runCollection(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		fmt.Fprintln(stderr, "usage: mta collection <name-or-id> [--output text|json] | mta collection create <name> [description] [--output text|json]")
		if len(args) == 0 {
			return errors.New("usage: mta collection <name-or-id> | mta collection create <name>")
		}
		return nil
	}

	flags := newFlags("collection", stderr)
	output := flags.String("output", "text", "text or json")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if err := checkOutput(*output); err != nil {
		return err
	}
	if len(positional) == 0 {
		return errors.New("usage: mta collection <name-or-id> | mta collection create <name>")
	}
	if apiKey == "" {
		return errors.New("MTA_API_KEY is required")
	}

	if positional[0] == "create" {
		rest := positional[1:]
		if len(rest) < 1 {
			return errors.New("usage: mta collection create <name> [description] [--output text|json]")
		}
		name := strings.TrimSpace(rest[0])
		if name == "" {
			return errors.New("collection name is required")
		}
		desc := ""
		if len(rest) > 1 {
			desc = strings.Join(rest[1:], " ")
		}
		data, err := apiCall(http.MethodPost, "/collections", map[string]string{"name": name, "description": desc})
		if err != nil {
			return err
		}
		var col collectionListEntry
		if err := json.Unmarshal(data, &col); err != nil || col.ID == "" {
			return errors.New("unexpected response creating collection")
		}
		if *output == "json" {
			return writeJSON(stdout, col)
		}
		_, err = fmt.Fprintf(stdout, "Created collection: %s (%s)\n", col.Name, col.ID)
		return err
	}

	if len(positional) != 1 {
		return errors.New("usage: mta collection <name-or-id> [--output text|json]")
	}

	resolved, err := resolveCollection(positional[0], false)
	if err != nil {
		return err
	}

	var raw struct {
		ID          string `json:"id"`
		Name        string `json:"name"`
		Description string `json:"description"`
		Color       string `json:"color"`
		Items       []struct {
			ID         string `json:"id"`
			ItemType   string `json:"item_type"`
			ItemID     string `json:"item_id"`
			ItemTitle  string `json:"item_title"`
			ItemStatus string `json:"item_status"`
		} `json:"items"`
	}
	if err := apiGetJSON("/collections/"+resolved.ID, &raw); err != nil {
		return err
	}

	view := collectionDetailView{
		ID:          raw.ID,
		Name:        raw.Name,
		Description: raw.Description,
		Color:       raw.Color,
		Items:       make([]collectionMemberItem, 0, len(raw.Items)),
	}
	for _, entry := range raw.Items {
		ref, kindName, ok := normalizeCollectionItem(entry.ItemType, entry.ItemID)
		if !ok {
			ref = strings.ToLower(entry.ItemType) + ":" + strings.ToLower(entry.ItemID)
			kindName = strings.ToLower(entry.ItemType)
		}
		view.Items = append(view.Items, collectionMemberItem{
			ID:     entry.ID,
			Ref:    ref,
			Type:   kindName,
			ItemID: strings.ToLower(entry.ItemID),
			Title:  entry.ItemTitle,
			Status: entry.ItemStatus,
		})
	}

	if *output == "json" {
		return writeJSON(stdout, view)
	}
	if _, err := fmt.Fprintf(stdout, "Collection: %s\n", view.Name); err != nil {
		return err
	}
	if view.Description != "" {
		if _, err := fmt.Fprintf(stdout, "  %s\n", view.Description); err != nil {
			return err
		}
	}
	if _, err := fmt.Fprintf(stdout, "  ID: %s\n\n", view.ID); err != nil {
		return err
	}
	if len(view.Items) == 0 {
		_, err := fmt.Fprintln(stdout, "  (no items)")
		return err
	}
	for _, item := range view.Items {
		title := item.Title
		if title == "" {
			title = "(untitled)"
		}
		if _, err := fmt.Fprintf(stdout, "  %s  %-10s  %s\n", item.Ref, item.Status, title); err != nil {
			return err
		}
	}
	return nil
}

func runChatCollection(args []string, stdout, stderr io.Writer) error {
	flags := newFlags("chat-collection", stderr)
	output := flags.String("output", "text", "text or json")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if len(positional) < 2 {
		return errors.New("usage: mta chat-collection <name-or-id> <message> [--output text|json]")
	}
	if err := checkOutput(*output); err != nil {
		return err
	}
	if apiKey == "" {
		return errors.New("MTA_API_KEY is required")
	}

	message := strings.TrimSpace(strings.Join(positional[1:], " "))
	if message == "" {
		return errors.New("usage: mta chat-collection <name-or-id> <message> [--output text|json]")
	}
	resolved, err := resolveCollection(positional[0], false)
	if err != nil {
		return err
	}

	data, err := apiCall(http.MethodPost, "/collections/"+resolved.ID+"/chat", map[string]string{"message": message})
	if err != nil {
		return err
	}
	var resp struct {
		Messages []itemChatMessage `json:"messages"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return fmt.Errorf("unexpected collection chat response: %w", err)
	}
	reply := ""
	for _, msg := range resp.Messages {
		if msg.Role == "assistant" {
			reply = msg.Content
		}
	}
	if *output == "json" {
		return writeJSON(stdout, map[string]interface{}{
			"ok":              true,
			"collection_id":   resolved.ID,
			"collection_name": resolved.Name,
			"reply":           reply,
		})
	}
	_, err = fmt.Fprintln(stdout, reply)
	return err
}
