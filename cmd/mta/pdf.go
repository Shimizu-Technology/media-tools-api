package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var maxPDFUploadBytes int64 = 50 << 20 // Matches the API's 50 MB request body limit.

func pdfMultipartOverhead(filename, boundary string) (int64, error) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	if err := mw.SetBoundary(boundary); err != nil {
		return 0, err
	}
	partHeader := make(textproto.MIMEHeader)
	partHeader.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename=%q`, filename))
	partHeader.Set("Content-Type", "application/pdf")
	if _, err := mw.CreatePart(partHeader); err != nil {
		return 0, err
	}
	if err := mw.Close(); err != nil {
		return 0, err
	}
	return int64(buf.Len()), nil
}

// pdfResult is the stable JSON shape for `mta pdf`.
type pdfResult struct {
	Kind        string `json:"kind"`
	Ref         string `json:"ref"`
	ID          string `json:"id"`
	Status      string `json:"status"`
	Title       string `json:"title,omitempty"`
	PageCount   int    `json:"page_count,omitempty"`
	WordCount   int    `json:"word_count,omitempty"`
	TextContent string `json:"text_content,omitempty"`
}

func cmdPDF(args []string) error { return runPDF(args, os.Stdout, os.Stderr) }

func runPDF(args []string, stdout, stderr io.Writer) error {
	flags := newFlags("pdf", stderr)
	output := flags.String("output", "text", "output format: text or json")
	timeout := flags.Duration("timeout", 5*time.Minute, "maximum time for upload and extraction")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if len(positional) != 1 {
		return errors.New("usage: mta pdf [flags] <file.pdf>")
	}
	if err := checkOutput(*output); err != nil {
		return err
	}
	if *timeout <= 0 {
		return errors.New("--timeout must be positive")
	}
	if apiKey == "" {
		return errors.New("MTA_API_KEY is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	result, err := submitPDF(ctx, positional[0])
	if err != nil {
		return err
	}
	fmt.Fprintf(stderr, "Extracted %s (%d pages, %d words)\n", result.Ref, result.PageCount, result.WordCount)
	if *output == "json" {
		return writeJSON(stdout, result)
	}
	_, err = fmt.Fprintln(stdout, result.TextContent)
	return err
}

func submitPDF(ctx context.Context, path string) (pdfResult, error) {
	if !strings.EqualFold(filepath.Ext(path), ".pdf") {
		return pdfResult{}, fmt.Errorf("unsupported file format %q; only .pdf files are accepted", strings.ToLower(filepath.Ext(path)))
	}
	file, err := os.Open(path)
	if err != nil {
		return pdfResult{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return pdfResult{}, err
	}
	if !info.Mode().IsRegular() {
		return pdfResult{}, errors.New("source must be a regular file")
	}
	boundary := "mta-pdf-upload-boundary"
	overhead, err := pdfMultipartOverhead(filepath.Base(path), boundary)
	if err != nil {
		return pdfResult{}, err
	}
	effectiveLimit := maxPDFUploadBytes - overhead
	if info.Size() > effectiveLimit {
		return pdfResult{}, fmt.Errorf("file exceeds the 50 MB PDF request limit (max file size %d bytes with multipart headers)", effectiveLimit)
	}

	reader, writer := io.Pipe()
	multipartWriter := multipart.NewWriter(writer)
	if err := multipartWriter.SetBoundary(boundary); err != nil {
		reader.Close()
		writer.Close()
		return pdfResult{}, err
	}
	go func() {
		partHeader := make(textproto.MIMEHeader)
		partHeader.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename=%q`, filepath.Base(path)))
		partHeader.Set("Content-Type", "application/pdf")
		part, copyErr := multipartWriter.CreatePart(partHeader)
		if copyErr == nil {
			_, copyErr = io.Copy(part, file)
		}
		if copyErr == nil {
			copyErr = multipartWriter.Close()
		}
		writer.CloseWithError(copyErr)
	}()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+"/pdf/extract", reader)
	if err != nil {
		reader.Close()
		return pdfResult{}, err
	}
	defer reader.Close()
	req.Header.Set("X-API-Key", apiKey)
	req.Header.Set("Content-Type", multipartWriter.FormDataContentType())
	data, err := sendTranscriptionRequest(req)
	if err != nil {
		return pdfResult{}, fmt.Errorf("extract pdf: %w", err)
	}

	var apiResp struct {
		ID           string `json:"id"`
		OriginalName string `json:"original_name"`
		PageCount    int    `json:"page_count"`
		TextContent  string `json:"text_content"`
		WordCount    int    `json:"word_count"`
		Status       string `json:"status"`
	}
	if err := json.Unmarshal(data, &apiResp); err != nil {
		return pdfResult{}, fmt.Errorf("decode pdf response: %w", err)
	}
	if apiResp.ID == "" || apiResp.Status == "" {
		return pdfResult{}, errors.New("API response omitted PDF extraction ID or status")
	}
	return pdfResult{
		Kind:        "pdf",
		Ref:         "pdf:" + strings.ToLower(apiResp.ID),
		ID:          strings.ToLower(apiResp.ID),
		Status:      apiResp.Status,
		Title:       apiResp.OriginalName,
		PageCount:   apiResp.PageCount,
		WordCount:   apiResp.WordCount,
		TextContent: apiResp.TextContent,
	}, nil
}
