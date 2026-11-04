package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type pipelineTransport func(*http.Request) (*http.Response, error)

func (f pipelineTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// This exercises real HTTP upload/read handlers and the real durable worker,
// with all outbound provider traffic intercepted locally.
func TestPipelineHTTPUploadToTitleAndCitedSummary(t *testing.T) {
	t.Setenv("AUTOMATIC_AUDIO_ENRICHMENT_ENABLED", "true")
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL required")
	}
	db, err := database.NewWithSimpleProtocol(url, true)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.RunMigrations(filepath.Join("..", "..", "migrations")); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	keyID := uuid.NewString()
	if _, err := db.ExecContext(ctx, `INSERT INTO api_keys(id,key_hash,key_prefix,name) VALUES($1,$2,'test','Pipeline fixture')`, keyID, uuid.NewString()); err != nil {
		t.Fatal(err)
	}
	defer db.ExecContext(ctx, `DELETE FROM api_keys WHERE id=$1`, keyID)
	var whisperCalls atomic.Int32
	original := http.DefaultTransport
	http.DefaultTransport = pipelineTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Hostname() == "127.0.0.1" {
			return original.RoundTrip(r)
		}
		var body string
		switch r.URL.Hostname() {
		case "api.openai.com":
			io.Copy(io.Discard, r.Body)
			if whisperCalls.Add(1) == 1 {
				return &http.Response{StatusCode: 503, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("simulated outage"))}, nil
			}
			body = `{"text":"Please call me tomorrow morning.","language":"en","duration":3,"segments":[{"text":"Please call me tomorrow morning.","start":0,"end":3}]}`
		case "openrouter.ai":
			request, _ := io.ReadAll(r.Body)
			content := "Tomorrow Morning Call"
			if !bytes.Contains(request, []byte("Give this recording")) {
				var id string
				if err := db.QueryRowContext(ctx, `SELECT id FROM media_segments WHERE item_type='audio' ORDER BY created_at DESC LIMIT 1`).Scan(&id); err != nil {
					return nil, err
				}
				content = fmt.Sprintf(`{"summary":{"text":"Call tomorrow morning.","citations":[%q]},"key_points":[],"action_items":[],"decisions":[],"topics":[]}`, id)
			}
			encoded, _ := json.Marshal(content)
			body = fmt.Sprintf(`{"model":"fake/model","choices":[{"message":{"content":%s},"finish_reason":"stop"}]}`, encoded)
		default:
			return nil, fmt.Errorf("unexpected outbound host")
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}, nil
	})
	defer func() { http.DefaultTransport = original }()
	transcriber := audio.NewTranscriber("fake-key")
	pool := worker.NewPool(1, 4, db, nil, summary.New("fake-key", "fake/model"))
	pool.SetAudioTranscriber(transcriber)
	pool.Start()
	defer pool.Stop()
	h := &Handler{DB: db, Worker: pool, AudioTranscriber: transcriber}
	router := gin.New()
	router.Use(func(c *gin.Context) { c.Set("api_key", &models.APIKey{ID: keyID}) })
	router.POST("/api/v1/audio/transcribe", h.TranscribeAudio)
	router.GET("/api/v1/audio/transcriptions/:id", h.GetAudioTranscription)
	server := httptest.NewServer(router)
	defer server.Close()
	path := filepath.Join(t.TempDir(), "New Recording.mov")
	if output, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:a", "aac", path).CombinedOutput(); err != nil {
		t.Fatalf("fixture %v %s", err, output)
	}
	var request bytes.Buffer
	form := multipart.NewWriter(&request)
	part, _ := form.CreateFormFile("file", "New Recording.mov")
	file, _ := os.Open(path)
	io.Copy(part, file)
	file.Close()
	form.Close()
	response, err := http.Post(server.URL+"/api/v1/audio/transcribe", form.FormDataContentType(), &request)
	if err != nil {
		t.Fatal(err)
	}
	var item models.AudioTranscription
	json.NewDecoder(response.Body).Decode(&item)
	response.Body.Close()
	if response.StatusCode != 202 {
		t.Fatalf("upload status %d", response.StatusCode)
	}
	defer db.ExecContext(ctx, `DELETE FROM background_jobs WHERE resource_id=$1`, item.ID)
	defer db.ExecContext(ctx, `DELETE FROM audio_transcriptions WHERE id=$1`, item.ID)
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		result, err := http.Get(server.URL + "/api/v1/audio/transcriptions/" + item.ID)
		if err != nil {
			t.Fatal(err)
		}
		json.NewDecoder(result.Body).Decode(&item)
		result.Body.Close()
		if item.Status == "failed" || item.SummaryStatus == "failed" {
			t.Fatalf("pipeline failed: %s %s", item.ErrorMessage, item.SummaryErrorMessage)
		}
		if item.OriginalName == "Tomorrow Morning Call" && item.SummaryStatus == "completed" && len(item.SummaryEvidence) > 2 {
			if whisperCalls.Load() != 2 {
				t.Fatalf("Whisper calls=%d", whisperCalls.Load())
			}
			t.Logf("HTTP upload 202; GET 200; transcript=%q title=%q summary=%q evidence=%s", item.TranscriptText, item.OriginalName, item.SummaryText, item.SummaryEvidence)
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("pipeline did not finish: status=%s summary=%s title=%s", item.Status, item.SummaryStatus, item.OriginalName)
}
