package handlers

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/storage"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

func reviewHandlerDB(t *testing.T) *database.DB {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL required")
	}
	db, err := database.NewWithSimpleProtocol(url, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestReviewDeleteNeverRemovesAudioBeforeOwnedRow(t *testing.T) {
	db := reviewHandlerDB(t)
	ctx := context.Background()
	user, key, id, keyOnly := uuid.NewString(), uuid.NewString(), uuid.NewString(), uuid.NewString()
	if _, err := db.Exec(`INSERT INTO users(id,email,password_hash) VALUES($1,$2,'unused')`, user, user+"@example.invalid"); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM users WHERE id=$1`, user)
	if _, err := db.Exec(`INSERT INTO api_keys(id,key_hash,key_prefix,name,user_id) VALUES($1,$2,'test','key',$3)`, key, uuid.NewString(), user); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM api_keys WHERE id=$1`, key)
	for _, audio := range []string{id, keyOnly} {
		if _, err := db.Exec(`INSERT INTO audio_transcriptions(id,filename,original_name,status,audio_s3_key,audio_s3_status,api_key_id) VALUES($1::uuid,'source','Source','completed',$1::text,'uploaded',$2)`, audio, key); err != nil {
			t.Fatal(err)
		}
		defer db.Exec(`DELETE FROM audio_transcriptions WHERE id=$1`, audio)
	}
	if _, err := db.Exec(`UPDATE audio_transcriptions SET user_id=$2 WHERE id=$1`, id, user); err != nil {
		t.Fatal(err)
	}
	h := &Handler{DB: db, AudioStorage: storage.NewS3("synthetic", "synthetic", "", "test-region", "test-bucket", "", 1)}
	original := http.DefaultTransport
	deletes := 0
	http.DefaultTransport = pipelineTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "DELETE" {
			return nil, fmt.Errorf("unexpected request")
		}
		audio := strings.TrimPrefix(r.URL.Path, "/")
		var count int
		if err := db.Get(&count, `SELECT count(*) FROM audio_transcriptions WHERE id=$1::uuid`, audio); err != nil {
			return nil, err
		}
		if count != 0 {
			return nil, fmt.Errorf("S3 deletion attempted before DB deletion")
		}
		deletes++
		return &http.Response{StatusCode: 204, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(""))}, nil
	})
	defer func() { http.DefaultTransport = original }()
	request := func(audio string, classic bool) *httptest.ResponseRecorder {
		router := gin.New()
		router.Use(func(c *gin.Context) {
			if classic {
				c.Set("api_key", &models.APIKey{ID: key, UserID: &user})
			} else {
				c.Set("user", &models.User{ID: user})
			}
		})
		router.DELETE("/audio/:id", h.DeleteAudioTranscription)
		out := httptest.NewRecorder()
		router.ServeHTTP(out, httptest.NewRequest("DELETE", "/audio/"+audio, nil))
		return out
	}
	if out := request(keyOnly, false); out.Code != 404 || deletes != 0 {
		t.Fatalf("key-only denied deletion=%d storage calls=%d", out.Code, deletes)
	}
	// Simulate DB deletion losing its ownership/row check after the initial read.
	function := "deny_audio_delete_" + strings.ReplaceAll(id, "-", "")
	if _, err := db.Exec(`CREATE FUNCTION ` + function + `() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$`); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DROP FUNCTION IF EXISTS ` + function + `() CASCADE`)
	if _, err := db.Exec(`CREATE TRIGGER ` + function + ` BEFORE DELETE ON audio_transcriptions FOR EACH ROW WHEN (OLD.id='` + id + `'::uuid) EXECUTE FUNCTION ` + function + `() `); err != nil {
		t.Fatal(err)
	}
	if out := request(id, false); out.Code != 404 || deletes != 0 {
		t.Fatalf("failed DB delete touched audio: %d calls=%d", out.Code, deletes)
	}
	if _, err := db.ExecContext(ctx, `DROP TRIGGER `+function+` ON audio_transcriptions`); err != nil {
		t.Fatal(err)
	}
	if out := request(id, false); out.Code != 200 || deletes != 1 {
		t.Fatalf("owned delete=%d calls=%d", out.Code, deletes)
	}
	if out := request(keyOnly, true); out.Code != 200 || deletes != 2 {
		t.Fatalf("classic key delete=%d calls=%d", out.Code, deletes)
	}
}

func TestReviewWorkspaceReadFailureReturns503(t *testing.T) {
	db := reviewHandlerDB(t)
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	h := &Handler{DB: db}
	router := gin.New()
	router.Use(func(c *gin.Context) { c.Set("user", &models.User{ID: uuid.NewString()}) })
	router.GET("/workspace", h.GetWorkspace)
	out := httptest.NewRecorder()
	router.ServeHTTP(out, httptest.NewRequest("GET", "/workspace", nil))
	if out.Code != 503 {
		t.Fatalf("workspace hid database failure: %d %s", out.Code, out.Body)
	}
}
