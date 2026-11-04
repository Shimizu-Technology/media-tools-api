package middleware

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

type recordingActivity struct {
	mu   sync.Mutex
	rows []models.AgentActivity
}

func (r *recordingActivity) RecordAgentActivity(_ context.Context, a models.AgentActivity) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.rows = append(r.rows, a)
	return nil
}

const (
	testUserID = "11111111-1111-4111-8111-111111111111"
	testItemID = "22222222-2222-4222-8222-222222222222"
)

func scopedEngine(key *models.APIKey, recorder AgentActivityRecorder) *gin.Engine {
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	group := engine.Group("/api/v1")
	group.Use(func(c *gin.Context) {
		if key != nil {
			c.Set(string(apiKeyContextKey), key)
		}
		c.Next()
	})
	group.Use(ScopedKeyAccess(recorder))
	ok := func(c *gin.Context) { c.Status(http.StatusOK) }
	group.GET("/library/items", ok)
	group.PATCH("/audio/transcriptions/:id", ok)
	group.DELETE("/audio/transcriptions/:id", ok)
	group.POST("/audio/uploads/presign", ok)
	group.GET("/keys", ok)
	group.POST("/user/keys", ok)
	group.POST("/collections", func(c *gin.Context) {
		SetActivityItem(c, "collection", testItemID)
		c.Status(http.StatusCreated)
	})
	return engine
}

func scopedKey(scopes ...string) *models.APIKey {
	user := testUserID
	return &models.APIKey{ID: "33333333-3333-4333-8333-333333333333", Name: "Agent", UserID: &user, Scopes: scopes}
}

func serve(engine *gin.Engine, method, target, body string) int {
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)
	return rec.Code
}

func TestScopedKeyAllowsOnlyGrantedScopes(t *testing.T) {
	cases := []struct {
		name   string
		scopes []string
		method string
		path   string
		want   int
	}{
		{"read lists library", []string{models.ScopeLibraryRead}, "GET", "/api/v1/library/items", 200},
		{"read cannot rename", []string{models.ScopeLibraryRead}, "PATCH", "/api/v1/audio/transcriptions/" + testItemID, 403},
		{"write can rename", []string{models.ScopeLibraryWrite}, "PATCH", "/api/v1/audio/transcriptions/" + testItemID, 200},
		{"write cannot delete", []string{models.ScopeLibraryWrite}, "DELETE", "/api/v1/audio/transcriptions/" + testItemID, 403},
		{"delete can delete", []string{models.ScopeLibraryDelete}, "DELETE", "/api/v1/audio/transcriptions/" + testItemID, 200},
		{"delete cannot read", []string{models.ScopeLibraryDelete}, "GET", "/api/v1/library/items", 403},
		{"upload can presign", []string{models.ScopeCaptureUpload}, "POST", "/api/v1/audio/uploads/presign", 200},
		{"upload cannot read", []string{models.ScopeCaptureUpload}, "GET", "/api/v1/library/items", 403},
		{"upload cannot rename", []string{models.ScopeCaptureUpload}, "PATCH", "/api/v1/audio/transcriptions/" + testItemID, 403},
		{"all scopes cannot list keys", models.AllAPIKeyScopes(), "GET", "/api/v1/keys", 403},
		{"all scopes cannot mint keys", models.AllAPIKeyScopes(), "POST", "/api/v1/user/keys", 403},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := serve(scopedEngine(scopedKey(tc.scopes...), nil), tc.method, tc.path, ""); got != tc.want {
				t.Fatalf("%s %s with %v = %d, want %d", tc.method, tc.path, tc.scopes, got, tc.want)
			}
		})
	}
}

func TestScopedKeyWithoutOwnerIsDeniedEverywhere(t *testing.T) {
	key := scopedKey(models.AllAPIKeyScopes()...)
	key.UserID = nil
	if got := serve(scopedEngine(key, nil), "GET", "/api/v1/library/items", ""); got != http.StatusForbidden {
		t.Fatalf("ownerless scoped key = %d, want 403", got)
	}
}

func TestClassicKeysAndUsersBypassScopeChecks(t *testing.T) {
	classic := &models.APIKey{ID: "k", Name: "Classic", Scopes: []string{}}
	if got := serve(scopedEngine(classic, nil), "GET", "/api/v1/keys", ""); got != http.StatusOK {
		t.Fatalf("classic key = %d, want 200", got)
	}
	if got := serve(scopedEngine(nil, nil), "GET", "/api/v1/keys", ""); got != http.StatusOK {
		t.Fatalf("no key = %d, want 200", got)
	}
}

func TestScopedKeyActivityRecordsWritesAndDenialsWithoutContent(t *testing.T) {
	recorder := &recordingActivity{}
	engine := scopedEngine(scopedKey(models.ScopeLibraryRead, models.ScopeLibraryWrite), recorder)

	serve(engine, "GET", "/api/v1/library/items?search=payroll+secrets", "")
	serve(engine, "PATCH", "/api/v1/audio/transcriptions/"+testItemID+"?q=confidential", `{"name":"Client SSN call"}`)
	serve(engine, "DELETE", "/api/v1/audio/transcriptions/"+testItemID, "")
	serve(engine, "POST", "/api/v1/collections", `{"name":"Brain Dump"}`)
	serve(engine, "PATCH", "/api/v1/audio/transcriptions/not-a-uuid", `{"name":"x"}`)

	if len(recorder.rows) != 4 {
		t.Fatalf("recorded %d rows, want 4 (rename, denied delete, create, bad-id rename): %#v", len(recorder.rows), recorder.rows)
	}
	rename, denied, create, badID := recorder.rows[0], recorder.rows[1], recorder.rows[2], recorder.rows[3]
	if rename.Method != "PATCH" || rename.Route != "/api/v1/audio/transcriptions/:id" || rename.ItemType != "audio" || rename.ItemID != testItemID || rename.StatusCode != 200 {
		t.Fatalf("rename row = %#v", rename)
	}
	if denied.Method != "DELETE" || denied.StatusCode != http.StatusForbidden {
		t.Fatalf("denied row = %#v", denied)
	}
	if create.ItemType != "collection" || create.ItemID != testItemID || create.StatusCode != http.StatusCreated {
		t.Fatalf("create row = %#v", create)
	}
	if badID.ItemID != "" {
		t.Fatalf("non-UUID path segment reached the log: %#v", badID)
	}
	for _, row := range recorder.rows {
		if row.UserID != testUserID || row.APIKeyName != "Agent" || row.APIKeyID == nil {
			t.Fatalf("row missing actor: %#v", row)
		}
		joined := strings.Join([]string{row.Method, row.Route, row.ItemType, row.ItemID, row.APIKeyName}, " ")
		for _, secret := range []string{"payroll", "confidential", "SSN", "Brain Dump"} {
			if strings.Contains(joined, secret) {
				t.Fatalf("activity row contains request content %q: %#v", secret, row)
			}
		}
	}
}

func TestClassicKeyWritesAreNotAudited(t *testing.T) {
	recorder := &recordingActivity{}
	engine := scopedEngine(&models.APIKey{ID: "k", Name: "Classic", Scopes: []string{}}, recorder)
	serve(engine, "PATCH", "/api/v1/audio/transcriptions/"+testItemID, "")
	if len(recorder.rows) != 0 {
		t.Fatalf("classic key wrote activity: %#v", recorder.rows)
	}
}

func TestNormalizeAPIKeyScopes(t *testing.T) {
	got, unknown := models.NormalizeAPIKeyScopes([]string{"library:write", "library:read", "library:write"})
	if unknown != "" || strings.Join(got, ",") != "library:read,library:write" {
		t.Fatalf("normalize = %v, unknown %q", got, unknown)
	}
	if _, unknown := models.NormalizeAPIKeyScopes([]string{"library:read", "admin"}); unknown != "admin" {
		t.Fatalf("unknown scope = %q, want admin", unknown)
	}
	if got, unknown := models.NormalizeAPIKeyScopes(nil); got != nil || unknown != "" {
		t.Fatalf("empty = %v, %q", got, unknown)
	}
}
