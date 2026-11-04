package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

func TestBackfillAdminHTTPAndRunSpecificCounts(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL required")
	}
	db, err := database.NewWithSimpleProtocol(url, true)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	pool := worker.NewPool(3, 10, db, nil, nil)
	defer pool.Stop()
	h := &Handler{DB: db, Worker: pool, AdminAPIKey: "synthetic-admin-test"}
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.POST("/api/v1/admin/backfills", h.CreateBackfill)
	router.GET("/api/v1/admin/backfills/:id", h.GetBackfill)
	request := func(method, path, body, admin, agent string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if admin != "" {
			req.Header.Set("X-Admin-Key", admin)
		}
		if agent != "" {
			req.Header.Set("X-API-Key", agent)
		}
		out := httptest.NewRecorder()
		router.ServeHTTP(out, req)
		return out
	}
	for _, method := range []string{"POST", "GET"} {
		path := "/api/v1/admin/backfills"
		if method == "GET" {
			path += "/" + uuid.NewString()
		}
		for _, tc := range []struct {
			admin, agent string
			want         int
		}{{"", "", 401}, {"wrong", "", 403}, {"", "scoped-agent", 403}, {h.AdminAPIKey, "scoped-agent", 403}} {
			out := request(method, path, `{"kind":"waveforms","dry_run":true}`, tc.admin, tc.agent)
			if out.Code != tc.want {
				t.Fatalf("%s auth=%d want %d", method, out.Code, tc.want)
			}
		}
	}
	for _, body := range []string{`{"kind":"enrichment","dry_run":true}`, `{"kind":"bad","dry_run":true}`, `{"kind":"waveforms"}`, `{"kind":"waveforms","user_id":"unexpected","dry_run":true}`} {
		if out := request("POST", "/api/v1/admin/backfills", body, h.AdminAPIKey, ""); out.Code != 400 {
			t.Fatalf("invalid %s=%d", body, out.Code)
		}
	}
	var beforeJobs, beforeRuns int
	db.Get(&beforeJobs, `SELECT count(*) FROM background_jobs`)
	db.Get(&beforeRuns, `SELECT count(*) FROM backfill_runs`)
	out := request("POST", "/api/v1/admin/backfills", `{"kind":"waveforms","dry_run":true}`, h.AdminAPIKey, "")
	if out.Code != 200 {
		t.Fatalf("dry run: %d %s", out.Code, out.Body)
	}
	var jobs, runs int
	db.Get(&jobs, `SELECT count(*) FROM background_jobs`)
	db.Get(&runs, `SELECT count(*) FROM backfill_runs`)
	if jobs != beforeJobs || runs != beforeRuns {
		t.Fatal("dry run wrote queue or run")
	}
	out = request("POST", "/api/v1/admin/backfills", `{"kind":"waveforms","dry_run":false}`, h.AdminAPIKey, "")
	var run struct {
		ID string `json:"id"`
	}
	json.Unmarshal(out.Body.Bytes(), &run)
	if out.Code != 202 || run.ID == "" {
		t.Fatalf("create %d %s", out.Code, out.Body)
	}
	defer db.Exec(`DELETE FROM backfill_runs WHERE id=$1`, run.ID)
	defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, run.ID)
	// Without starting a worker, the immediate response already has a durable
	// dispatcher and can report zero child jobs honestly.
	path := "/api/v1/admin/backfills/" + run.ID
	out = request("GET", path, "", h.AdminAPIKey, "")
	var progress database.BackfillProgress
	json.Unmarshal(out.Body.Bytes(), &progress)
	if out.Code != 200 || progress.DispatchStatus != "queued" || progress.Queued != 0 {
		t.Fatalf("initial progress %d %s", out.Code, out.Body)
	}
	for _, status := range []string{"queued", "running", "completed", "failed"} {
		var job string
		if err := db.QueryRow(`INSERT INTO background_jobs(job_type,resource_id,status) VALUES('audio_waveform',$1,$2) RETURNING id`, uuid.NewString(), status).Scan(&job); err != nil {
			t.Fatal(err)
		}
		defer db.Exec(`DELETE FROM background_jobs WHERE id=$1`, job)
		if _, err := db.Exec(`INSERT INTO backfill_run_jobs(run_id,job_id) VALUES($1,$2)`, run.ID, job); err != nil {
			t.Fatal(err)
		}
	}
	fresh := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO background_jobs(job_type,resource_id) VALUES('audio_transcription',$1)`, fresh); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, fresh)
	out = request("GET", path, "", h.AdminAPIKey, "")
	json.Unmarshal(out.Body.Bytes(), &progress)
	if out.Code != http.StatusOK || progress.Queued != 1 || progress.Running != 1 || progress.Completed != 1 || progress.Failed != 1 {
		t.Fatalf("run counts %d %s", out.Code, out.Body)
	}
	if out := request("GET", "/api/v1/admin/backfills/"+uuid.NewString(), "", h.AdminAPIKey, ""); out.Code != 404 {
		t.Fatal(out.Code)
	}
}
