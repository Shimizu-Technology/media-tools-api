package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func withTestAPI(t *testing.T, handler http.Handler) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	oldBase, oldKey := apiBase, apiKey
	apiBase, apiKey = server.URL+"/api/v1", "test-key"
	t.Cleanup(func() { apiBase, apiKey = oldBase, oldKey })
}

func TestTranscribeVideoPrintsOnlyTranscriptToStdout(t *testing.T) {
	checks := 0
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-API-Key") != "test-key" {
			t.Errorf("missing API key")
		}
		switch r.URL.Path {
		case "/api/v1/transcripts":
			var payload map[string]string
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Error(err)
			}
			if payload["url"] != "https://youtu.be/example" {
				t.Errorf("unexpected URL: %q", payload["url"])
			}
			w.WriteHeader(http.StatusAccepted)
			io.WriteString(w, `{"id":"video-1","status":"pending"}`)
		case "/api/v1/transcripts/video-1":
			checks++
			if checks == 1 {
				io.WriteString(w, `{"id":"video-1","status":"processing"}`)
			} else {
				io.WriteString(w, `{"id":"video-1","status":"completed","transcript_text":"Useful transcript text","word_count":3}`)
			}
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
		}
	}))
	var stdout, stderr bytes.Buffer
	if err := runTranscribe([]string{"--interval", "1ms", "https://youtu.be/example"}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "Useful transcript text\n" {
		t.Errorf("stdout = %q", stdout.String())
	}
	if !strings.Contains(stderr.String(), "video:video-1") {
		t.Errorf("missing progress: %q", stderr.String())
	}
}

func TestTranscribeFileStreamsMultipartAndResumesAsJSON(t *testing.T) {
	source := filepath.Join(t.TempDir(), "memo.m4a")
	if err := os.WriteFile(source, []byte("synthetic audio fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/audio/transcribe":
			if err := r.ParseMultipartForm(1024); err != nil {
				t.Error(err)
			}
			file, header, err := r.FormFile("file")
			if err != nil {
				t.Error(err)
				return
			}
			defer file.Close()
			data, _ := io.ReadAll(file)
			if header.Filename != "memo.m4a" || string(data) != "synthetic audio fixture" || r.FormValue("content_type") != "voice_memo" {
				t.Errorf("unexpected upload: %q, %q, %q", header.Filename, data, r.FormValue("content_type"))
			}
			w.WriteHeader(http.StatusAccepted)
			io.WriteString(w, `{"id":"audio-1","status":"pending"}`)
		case "/api/v1/audio/transcriptions/audio-1":
			io.WriteString(w, `{"id":"audio-1","status":"completed","transcript_text":"A memo"}`)
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
		}
	}))
	var stdout, stderr bytes.Buffer
	if err := runTranscribe([]string{"--no-wait", "--output", "json", "--content-type", "voice_memo", source}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	var queued transcriptionResult
	if err := json.Unmarshal(stdout.Bytes(), &queued); err != nil {
		t.Fatal(err)
	}
	if queued.reference() != "audio:audio-1" || queued.Status != "pending" {
		t.Errorf("unexpected queued result: %+v", queued)
	}
	stdout.Reset()
	if err := runTranscribe([]string{"--resume", queued.reference()}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "A memo\n" {
		t.Errorf("resume stdout = %q", stdout.String())
	}
}

func TestTranscribeFailureLeavesStdoutEmptyAndReportsReference(t *testing.T) {
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/transcripts") {
			w.WriteHeader(http.StatusAccepted)
			io.WriteString(w, `{"id":"failed-1","status":"pending"}`)
			return
		}
		io.WriteString(w, `{"id":"failed-1","status":"failed","error_message":"source unavailable"}`)
	}))
	var stdout, stderr bytes.Buffer
	err := runTranscribe([]string{"https://youtu.be/example"}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "video:failed-1 failed: source unavailable") {
		t.Fatalf("error = %v", err)
	}
	if stdout.Len() != 0 {
		t.Errorf("unexpected stdout: %q", stdout.String())
	}
}

func TestTranscribeRejectsUnsupportedFileBeforeRequest(t *testing.T) {
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("request must not be sent") }))
	var stdout, stderr bytes.Buffer
	err := runTranscribe([]string{"recording.mov"}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "unsupported file format") {
		t.Fatal(fmt.Sprint(err))
	}
}

func TestResumeStopsOnUnauthorizedInsteadOfPolling(t *testing.T) {
	checks := 0
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		checks++
		w.WriteHeader(http.StatusUnauthorized)
		io.WriteString(w, `{"error":"unauthorized"}`)
	}))
	var stdout, stderr bytes.Buffer
	err := runTranscribe([]string{"--resume", "audio:existing-1", "--interval", "1ms"}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "HTTP 401") {
		t.Fatalf("error = %v", err)
	}
	if checks != 1 || stdout.Len() != 0 {
		t.Errorf("checks=%d stdout=%q", checks, stdout.String())
	}
}

func TestResumeRetriesTransientResponseContainingDecodeMarker(t *testing.T) {
	checks := 0
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		checks++
		if checks == 1 {
			w.WriteHeader(http.StatusTooManyRequests)
			io.WriteString(w, `{"message":"decode API response"}`)
			return
		}
		io.WriteString(w, `{"id":"existing-1","status":"completed","transcript_text":"Recovered transcript"}`)
	}))
	var stdout, stderr bytes.Buffer
	if err := runTranscribe([]string{"--resume", "audio:existing-1", "--interval", "1ms"}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	if checks != 2 || stdout.String() != "Recovered transcript\n" {
		t.Errorf("checks=%d stdout=%q", checks, stdout.String())
	}
}
