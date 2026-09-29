package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// transcriptionResult is deliberately smaller than the API's record. JSON
// output is a stable CLI contract without leaking storage or account fields.
type transcriptionResult struct {
	Kind           string `json:"kind"`
	ID             string `json:"id"`
	Status         string `json:"status"`
	Title          string `json:"title,omitempty"`
	TranscriptText string `json:"transcript_text,omitempty"`
	WordCount      int    `json:"word_count,omitempty"`
	ErrorMessage   string `json:"error_message,omitempty"`
}

type apiStatusError struct {
	status int
	body   string
}

var errMalformedTranscriptionResponse = errors.New("malformed transcription response")

func (e apiStatusError) Error() string {
	return fmt.Sprintf("HTTP %d: %s", e.status, e.body)
}

func (r transcriptionResult) reference() string { return r.Kind + ":" + r.ID }

func parseReference(value string) (transcriptionResult, error) {
	kind, id, found := strings.Cut(value, ":")
	if !found {
		kind, id = "video", value
	} // Existing video IDs remain valid.
	if (kind != "video" && kind != "audio") || id == "" || strings.ContainsAny(id, "/?#") {
		return transcriptionResult{}, fmt.Errorf("invalid reference %q; use video:<id> or audio:<id>", value)
	}
	return transcriptionResult{Kind: kind, ID: id}, nil
}

func runTranscribe(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("transcribe", flag.ContinueOnError)
	flags.SetOutput(stderr)
	output := flags.String("output", "text", "output format: text or json")
	noWait := flags.Bool("no-wait", false, "return a resumable reference immediately")
	resume := flags.String("resume", "", "resume an existing video:<id> or audio:<id>")
	timeout := flags.Duration("timeout", 30*time.Minute, "maximum time for upload and processing")
	interval := flags.Duration("interval", 5*time.Second, "status polling interval")
	contentType := flags.String("content-type", "general", "file type: general, phone_call, meeting, voice_memo, interview, lecture")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if *output != "text" && *output != "json" {
		return fmt.Errorf("--output must be text or json")
	}
	if *timeout <= 0 || *interval <= 0 {
		return fmt.Errorf("--timeout and --interval must be positive")
	}
	if apiKey == "" {
		return fmt.Errorf("MTA_API_KEY is required")
	}

	var result transcriptionResult
	if *resume != "" {
		if *noWait {
			return fmt.Errorf("--no-wait cannot be combined with --resume")
		}
		if flags.NArg() != 0 {
			return fmt.Errorf("--resume cannot be combined with a source")
		}
		var err error
		result, err = parseReference(*resume)
		if err != nil {
			return err
		}
	} else {
		if flags.NArg() != 1 {
			return fmt.Errorf("usage: mta transcribe [flags] <url-or-file>")
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	if *resume == "" {
		source := flags.Arg(0)
		var err error
		lowerSource := strings.ToLower(source)
		if strings.HasPrefix(lowerSource, "http://") || strings.HasPrefix(lowerSource, "https://") {
			parsed, parseErr := url.Parse(source)
			if parseErr != nil {
				return parseErr
			}
			if parsed.Host == "" {
				return fmt.Errorf("video URL has no host")
			}
			if *contentType != "general" {
				return fmt.Errorf("--content-type applies only to local files")
			}
			result, err = submitVideo(ctx, source)
		} else {
			result, err = submitFile(ctx, source, *contentType)
		}
		if err != nil {
			return err
		}
		fmt.Fprintf(stderr, "Submitted %s (%s)\n", result.reference(), result.Status)
	}
	if *noWait {
		return printTranscription(stdout, result, *output, true)
	}
	result, err := waitForTranscription(ctx, result, *interval, stderr)
	if err != nil {
		return err
	}
	return printTranscription(stdout, result, *output, false)
}

func submitVideo(ctx context.Context, source string) (transcriptionResult, error) {
	body, err := json.Marshal(map[string]string{"url": source})
	if err != nil {
		return transcriptionResult{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+"/transcripts", strings.NewReader(string(body)))
	if err != nil {
		return transcriptionResult{}, err
	}
	req.Header.Set("X-API-Key", apiKey)
	req.Header.Set("Content-Type", "application/json")
	data, err := sendTranscriptionRequest(req)
	if err != nil {
		return transcriptionResult{}, fmt.Errorf("submit video: %w", err)
	}
	return decodeTranscription("video", data)
}

func submitFile(ctx context.Context, path, contentType string) (transcriptionResult, error) {
	allowedContent := map[string]bool{"general": true, "phone_call": true, "meeting": true, "voice_memo": true, "interview": true, "lecture": true}
	if !allowedContent[contentType] {
		return transcriptionResult{}, fmt.Errorf("unsupported --content-type %q", contentType)
	}
	extension := strings.ToLower(filepath.Ext(path))
	allowedFormat := map[string]bool{".mp3": true, ".wav": true, ".caf": true, ".m4a": true, ".mp4": true, ".ogg": true, ".flac": true, ".webm": true}
	if !allowedFormat[extension] {
		return transcriptionResult{}, fmt.Errorf("unsupported file format %q", extension)
	}
	file, err := os.Open(path)
	if err != nil {
		return transcriptionResult{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return transcriptionResult{}, err
	}
	if !info.Mode().IsRegular() {
		return transcriptionResult{}, fmt.Errorf("source must be a regular file")
	}
	if info.Size() > 2<<30 {
		return transcriptionResult{}, fmt.Errorf("file exceeds the 2 GB upload limit")
	}

	reader, writer := io.Pipe()
	multipartWriter := multipart.NewWriter(writer)
	go func() {
		partHeader := make(textproto.MIMEHeader)
		partHeader.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename=%q`, filepath.Base(path)))
		mediaType := mime.TypeByExtension(extension)
		if mediaType == "" {
			mediaType = "application/octet-stream"
		}
		partHeader.Set("Content-Type", mediaType)
		part, copyErr := multipartWriter.CreatePart(partHeader)
		if copyErr == nil {
			_, copyErr = io.Copy(part, file)
		}
		if copyErr == nil {
			copyErr = multipartWriter.WriteField("content_type", contentType)
		}
		if copyErr == nil {
			copyErr = multipartWriter.Close()
		}
		writer.CloseWithError(copyErr)
	}()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+"/audio/transcribe", reader)
	if err != nil {
		reader.Close()
		return transcriptionResult{}, err
	}
	defer reader.Close()
	req.Header.Set("X-API-Key", apiKey)
	req.Header.Set("Content-Type", multipartWriter.FormDataContentType())
	data, err := sendTranscriptionRequest(req)
	if err != nil {
		return transcriptionResult{}, fmt.Errorf("upload file: %w", err)
	}
	return decodeTranscription("audio", data)
}

func sendTranscriptionRequest(req *http.Request) ([]byte, error) {
	// The standard CLI client's 60 second timeout is too short for a large
	// upload. The command's context supplies the overall deadline instead.
	resp, err := (&http.Client{}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	const maxResponseBytes = 32 << 20
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxResponseBytes {
		return nil, fmt.Errorf("API response exceeded 32 MB")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, apiStatusError{status: resp.StatusCode, body: strings.TrimSpace(string(data))}
	}
	return data, nil
}

func decodeTranscription(kind string, data []byte) (transcriptionResult, error) {
	result := transcriptionResult{Kind: kind}
	if err := json.Unmarshal(data, &result); err != nil {
		return result, fmt.Errorf("%w: decode API response: %v", errMalformedTranscriptionResponse, err)
	}
	if result.ID == "" || result.Status == "" {
		return result, fmt.Errorf("%w: API response omitted transcription ID or status", errMalformedTranscriptionResponse)
	}
	return result, nil
}

func fetchTranscription(ctx context.Context, ref transcriptionResult) (transcriptionResult, error) {
	path := "/transcripts/" + url.PathEscape(ref.ID)
	if ref.Kind == "audio" {
		path = "/audio/transcriptions/" + url.PathEscape(ref.ID)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiBase+path, nil)
	if err != nil {
		return ref, err
	}
	req.Header.Set("X-API-Key", apiKey)
	data, err := sendTranscriptionRequest(req)
	if err != nil {
		return ref, err
	}
	return decodeTranscription(ref.Kind, data)
}

func waitForTranscription(ctx context.Context, ref transcriptionResult, interval time.Duration, stderr io.Writer) (transcriptionResult, error) {
	lastStatus := ""
	for {
		result, err := fetchTranscription(ctx, ref)
		if err == nil {
			if result.Status != lastStatus {
				fmt.Fprintf(stderr, "%s: %s\n", ref.reference(), result.Status)
				lastStatus = result.Status
			}
			switch result.Status {
			case "completed":
				if result.TranscriptText == "" {
					return result, fmt.Errorf("%s completed without transcript text", ref.reference())
				}
				return result, nil
			case "failed", "cancelled":
				return result, fmt.Errorf("%s %s: %s", ref.reference(), result.Status, result.ErrorMessage)
			case "pending", "processing":
			default:
				return result, fmt.Errorf("%s returned unknown status %q", ref.reference(), result.Status)
			}
		} else {
			// Retry transient status failures. Invalid credentials, missing
			// records, and malformed responses require human intervention.
			var statusError apiStatusError
			if errors.As(err, &statusError) && statusError.status < 500 && statusError.status != http.StatusTooManyRequests {
				return ref, fmt.Errorf("check %s: %w", ref.reference(), err)
			}
			if errors.Is(err, errMalformedTranscriptionResponse) {
				return ref, fmt.Errorf("check %s: %w", ref.reference(), err)
			}
			fmt.Fprintf(stderr, "Status check for %s failed; retrying: %v\n", ref.reference(), err)
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				return ref, fmt.Errorf("timed out waiting for %s; resume with mta transcribe --resume %s", ref.reference(), ref.reference())
			}
			return ref, ctx.Err()
		case <-timer.C:
		}
	}
}

func printTranscription(stdout io.Writer, result transcriptionResult, output string, pending bool) error {
	if output == "json" {
		return json.NewEncoder(stdout).Encode(result)
	}
	if pending {
		_, err := fmt.Fprintln(stdout, result.reference())
		return err
	}
	_, err := fmt.Fprintln(stdout, result.TranscriptText)
	return err
}
