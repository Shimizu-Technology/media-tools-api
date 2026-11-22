package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPDFUploadStreamsMultipartAndReturnsJSON(t *testing.T) {
	source := filepath.Join(t.TempDir(), "contract.pdf")
	if err := os.WriteFile(source, []byte("%PDF-1.4\nfake pdf bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/pdf/extract" || r.Method != http.MethodPost {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("X-API-Key") != "test-key" {
			t.Errorf("missing API key")
		}
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
		if header.Filename != "contract.pdf" || !strings.HasPrefix(string(data), "%PDF-1.4") {
			t.Errorf("unexpected upload: %q %q", header.Filename, string(data))
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"id":"`+pdfID+`","original_name":"contract.pdf","page_count":3,"word_count":42,"status":"completed","text_content":"Lease terms here."}`)
	}))

	// Flags after positional path work via parseInterspersed.
	stdout, stderr, err := runCLI(t, runPDF, source, "--output", "json")
	if err != nil {
		t.Fatal(err)
	}
	var got pdfResult
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("bad JSON: %v\n%s", err, stdout)
	}
	if got.Ref != "pdf:"+pdfID || got.PageCount != 3 || got.WordCount != 42 || got.TextContent != "Lease terms here." {
		t.Fatalf("got = %#v", got)
	}
	if !strings.Contains(stderr, "pdf:"+pdfID) {
		t.Errorf("stderr missing ref: %q", stderr)
	}

	// Text output prints only extracted text on stdout.
	stdout, _, err = runCLI(t, runPDF, source)
	if err != nil || stdout != "Lease terms here.\n" {
		t.Fatalf("text stdout = %q, %v", stdout, err)
	}
}

func TestPDFRejectsNonPDFAndSurfacesOCRError(t *testing.T) {
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		io.WriteString(w, `{"error":"ocr_required","message":"PDF appears to be scanned","code":422}`)
	}))
	if _, _, err := runCLI(t, runPDF, "notes.txt"); err == nil || !strings.Contains(err.Error(), "only .pdf files") {
		t.Fatalf("non-pdf should fail before upload, got %v", err)
	}
	source := filepath.Join(t.TempDir(), "scan.pdf")
	if err := os.WriteFile(source, []byte("%PDF-1.4"), 0o600); err != nil {
		t.Fatal(err)
	}
	stdout, _, err := runCLI(t, runPDF, source)
	if err == nil || !strings.Contains(err.Error(), "422") || !strings.Contains(err.Error(), "ocr_required") {
		t.Fatalf("expected 422 ocr_required, got %v", err)
	}
	if stdout != "" {
		t.Fatalf("stdout should be empty on failure, got %q", stdout)
	}
}

func TestTranscribeAcceptsFlagsAfterPositionalSource(t *testing.T) {
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/transcripts" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		w.WriteHeader(http.StatusAccepted)
		io.WriteString(w, `{"id":"video-9","status":"pending"}`)
	}))
	var stdout, stderr bytes.Buffer
	if err := runTranscribe([]string{"https://youtu.be/example", "--no-wait", "--output", "json"}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	var got transcriptionResult
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("bad JSON: %v\n%s", err, stdout.String())
	}
	if got.reference() != "video:video-9" || got.Status != "pending" {
		t.Fatalf("got = %#v", got)
	}
}

func TestCollectionsAndCollectionChatJSON(t *testing.T) {
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/collections":
			io.WriteString(w, `[{"id":"`+colID+`","name":"Brain Dump","description":"Notes","item_count":2}]`)
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/collections/"+colID:
			io.WriteString(w, `{"id":"`+colID+`","name":"Brain Dump","description":"Notes","items":[{"id":"row-1","item_type":"audio","item_id":"`+audioID+`","item_title":"Memo","item_status":"completed"},{"id":"row-2","item_type":"transcript","item_id":"`+videoID+`","item_title":"Talk","item_status":"completed"}]}`)
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/collections":
			w.WriteHeader(http.StatusCreated)
			io.WriteString(w, `{"id":"`+otherCol+`","name":"Taxes","description":"2026"}`)
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/collections/"+colID+"/chat":
			io.WriteString(w, `{"messages":[{"role":"assistant","content":"Old answer"},{"role":"user","content":"Latest?"},{"role":"assistant","content":"Latest answer"}]}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))

	stdout, _, err := runCLI(t, runCollections, "--output", "json")
	if err != nil {
		t.Fatal(err)
	}
	var list []collectionListEntry
	if err := json.Unmarshal([]byte(stdout), &list); err != nil || len(list) != 1 || list[0].ID != colID {
		t.Fatalf("collections = %q, %v", stdout, err)
	}

	// Resolve collection by name case-insensitively and emit typed refs.
	stdout, _, err = runCLI(t, runCollection, "brain dump", "--output", "json")
	if err != nil {
		t.Fatal(err)
	}
	var detail collectionDetailView
	if err := json.Unmarshal([]byte(stdout), &detail); err != nil {
		t.Fatalf("collection detail JSON: %v\n%s", err, stdout)
	}
	if len(detail.Items) != 2 || detail.Items[0].Ref != "audio:"+audioID || detail.Items[1].Ref != "video:"+videoID {
		t.Fatalf("items = %#v", detail.Items)
	}

	stdout, _, err = runCLI(t, runCollection, "create", "Taxes", "2026", "--output", "json")
	if err != nil || !strings.Contains(stdout, otherCol) {
		t.Fatalf("create = %q, %v", stdout, err)
	}

	// chat-collection returns only the latest assistant reply.
	stdout, _, err = runCLI(t, runChatCollection, "Brain Dump", "Latest?", "--output", "json")
	if err != nil || !strings.Contains(stdout, `"reply": "Latest answer"`) || strings.Contains(stdout, "Old answer") {
		t.Fatalf("chat-collection = %q, %v", stdout, err)
	}

	// Flags before `create` and plain text mode both work.
	stdout, _, err = runCLI(t, runCollection, "--output", "json", "create", "Taxes", "2026")
	if err != nil || !strings.Contains(stdout, otherCol) {
		t.Fatalf("flags-before-create = %q, %v", stdout, err)
	}
	stdout, _, err = runCLI(t, runCollection, "create", "Taxes")
	if err != nil || !strings.Contains(stdout, "Created collection: Taxes") {
		t.Fatalf("create text = %q, %v", stdout, err)
	}

	// Uppercase collection UUID resolves cleanly.
	stdout, _, err = runCLI(t, runCollection, strings.ToUpper(colID), "--output", "json")
	if err != nil || !strings.Contains(stdout, colID) {
		t.Fatalf("uppercase UUID lookup = %q, %v", stdout, err)
	}

	// Invalid --output rejected.
	if _, _, err := runCLI(t, runCollections, "--output", "xml"); err == nil {
		t.Fatal("invalid --output should fail")
	}
}

func TestCollectionsEdgeCasesAmbiguousNameUnknownTypeAnd409Chat(t *testing.T) {
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/collections":
			io.WriteString(w, `[{"id":"`+colID+`","name":"Dup"},{"id":"`+otherCol+`","name":"Dup"}]`)
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/collections/"+colID:
			io.WriteString(w, `{"id":"`+colID+`","name":"Dup","items":[{"id":"row-x","item_type":"custom","item_id":"`+audioID+`","item_title":"Mystery","item_status":"completed"}]}`)
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/collections/"+colID+"/chat":
			w.WriteHeader(http.StatusConflict)
			io.WriteString(w, `{"error":"collection_not_ready","message":"No completed items"}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))

	if _, _, err := runCLI(t, runCollection, "Dup"); err == nil || !strings.Contains(err.Error(), "use the collection id") {
		t.Fatalf("ambiguous name should fail cleanly, got %v", err)
	}

	stdout, _, err := runCLI(t, runCollection, colID, "--output", "json")
	if err != nil || !strings.Contains(stdout, `"ref": "custom:`+audioID+`"`) {
		t.Fatalf("unknown item_type fallback = %q, %v", stdout, err)
	}

	if _, _, err := runCLI(t, runChatCollection, colID, "Hello?"); err == nil || !strings.Contains(err.Error(), "409") {
		t.Fatalf("expected 409 from collection chat, got %v", err)
	}
}

func TestPDFMultipartRequestBodyCapEnforced(t *testing.T) {
	oldMax := maxPDFUploadBytes
	const testCap int64 = 512
	maxPDFUploadBytes = testCap
	t.Cleanup(func() { maxPDFUploadBytes = oldMax })

	overhead, err := pdfMultipartOverhead("cap.pdf", "mta-pdf-upload-boundary")
	if err != nil {
		t.Fatal(err)
	}
	effective := testCap - overhead

	var receivedBodyLen int64
	withTestAPI(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		receivedBodyLen = int64(len(body))
		if receivedBodyLen > testCap {
			t.Errorf("request body %d exceeded server cap %d", receivedBodyLen, testCap)
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"id":"`+pdfID+`","original_name":"cap.pdf","page_count":1,"word_count":1,"status":"completed","text_content":"ok"}`)
	}))

	dir := t.TempDir()
	atLimit := filepath.Join(dir, "cap.pdf")
	if err := os.WriteFile(atLimit, bytes.Repeat([]byte("a"), int(effective)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := runCLI(t, runPDF, atLimit, "--output", "json"); err != nil {
		t.Fatalf("file at effective limit should succeed: %v", err)
	}
	if receivedBodyLen != testCap {
		t.Fatalf("expected exact multipart body size %d, got %d", testCap, receivedBodyLen)
	}

	overLimit := filepath.Join(dir, "cap.pdf")
	if err := os.WriteFile(overLimit, bytes.Repeat([]byte("a"), int(effective+1)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := runCLI(t, runPDF, overLimit); err == nil || !strings.Contains(err.Error(), "50 MB PDF request limit") {
		t.Fatalf("file exceeding multipart cap should fail before upload, got %v", err)
	}
}
