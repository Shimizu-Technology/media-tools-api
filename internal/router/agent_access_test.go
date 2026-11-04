package router

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// neverScopedPrefixes are the account-level surfaces a scoped key must never
// reach, however many scopes it holds. A registered /api/v1 route must be
// either in the scoped-key allow list or under one of these prefixes; a new
// route that is neither fails this test until someone classifies it.
var neverScopedPrefixes = []string{
	"/api/v1/keys",
	"/api/v1/user/",
	"/api/v1/auth/",
	"/api/v1/account",
	"/api/v1/workspace",
	"/api/v1/webhooks",
	"/api/v1/ops/",
	"/api/v1/ai-content-reports",
	"/api/v1/health",
	"/api/v1/ready",
}

func registeredAPIRoutes(t *testing.T) []gin.RouteInfo {
	t.Helper()
	gin.SetMode(gin.TestMode)
	// Every optional route group on, so a flag-gated route is also walked. The
	// zero DB is never queried: the test only reads the route table.
	engine := Setup(RouterConfig{
		DB:                            &database.DB{},
		FirstPartyAuthEnabled:         true,
		FirstPartyPasswordAuthEnabled: true,
		WebCookieAuthEnabled:          true,
	})
	var routes []gin.RouteInfo
	for _, route := range engine.Routes() {
		if strings.HasPrefix(route.Path, "/api/v1/") {
			routes = append(routes, route)
		}
	}
	if len(routes) < 50 {
		t.Fatalf("only %d /api/v1 routes registered; the walk is not seeing the router", len(routes))
	}
	return routes
}

func hasAnyPrefix(path string, prefixes []string) bool {
	for _, prefix := range prefixes {
		if strings.HasPrefix(path, prefix) {
			return true
		}
	}
	return false
}

func TestScopedKeysFailClosedOnEveryRegisteredRoute(t *testing.T) {
	allScopes := models.AllAPIKeyScopes()
	allowed := map[string]bool{}
	for _, route := range middleware.ScopedKeyAllowedRoutes() {
		allowed[route] = true
	}

	registered := map[string]bool{}
	for _, route := range registeredAPIRoutes(t) {
		key := route.Method + " " + route.Path
		registered[key] = true
		permitted := middleware.ScopedKeyPermits(allScopes, route.Method, route.Path)
		forbidden := hasAnyPrefix(route.Path, neverScopedPrefixes)

		switch {
		case forbidden && permitted:
			t.Errorf("%s is an account-level route but a fully scoped key can reach it", key)
		case !forbidden && !allowed[key]:
			t.Errorf("%s is not classified for scoped keys: add it to scopedKeyRules in middleware/agent_access.go, or to neverScopedPrefixes here", key)
		case allowed[key] && !permitted:
			t.Errorf("%s is in the allow list but no scope unlocks it", key)
		}
		if !allowed[key] && permitted {
			t.Errorf("%s is permitted without being in the allow list", key)
		}
		if middleware.ScopedKeyPermits(nil, route.Method, route.Path) {
			t.Errorf("%s is permitted to a key with no scopes", key)
		}
	}

	for route := range allowed {
		if !registered[route] {
			t.Errorf("allow-list entry %q matches no registered route; remove or fix it", route)
		}
	}
}

func TestEachScopeUnlocksOnlyItsOwnRoutes(t *testing.T) {
	reachable := func(scope string) map[string]bool {
		out := map[string]bool{}
		for _, route := range registeredAPIRoutes(t) {
			if middleware.ScopedKeyPermits([]string{scope}, route.Method, route.Path) {
				out[route.Method+" "+route.Path] = true
			}
		}
		return out
	}

	upload := reachable(models.ScopeCaptureUpload)
	if len(upload) != 2 || !upload["POST /api/v1/audio/uploads/presign"] || !upload["POST /api/v1/audio/uploads/complete"] {
		t.Fatalf("capture:upload must reach only presign and complete, got %v", upload)
	}
	for route := range reachable(models.ScopeLibraryRead) {
		if !strings.HasPrefix(route, "GET ") {
			t.Errorf("library:read reaches non-GET route %s", route)
		}
	}
	for route := range reachable(models.ScopeLibraryDelete) {
		if !strings.HasPrefix(route, "DELETE ") {
			t.Errorf("library:delete reaches non-DELETE route %s", route)
		}
	}
	for route := range reachable(models.ScopeLibraryWrite) {
		// Reading a batch refreshes its stored counts, so it is deliberately a write.
		if strings.HasPrefix(route, "GET ") && route != "GET /api/v1/batches/:id" {
			t.Errorf("library:write reaches read route %s", route)
		}
		if strings.HasPrefix(route, "DELETE ") && !strings.Contains(route, "/items/:itemId") {
			t.Errorf("library:write reaches destructive route %s", route)
		}
	}
}

type agentHarness struct {
	t      *testing.T
	db     *database.DB
	engine *gin.Engine
}

func (h *agentHarness) do(method, path, credentialHeader, credential, body string) (int, []byte) {
	h.t.Helper()
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	switch credentialHeader {
	case "key":
		request.Header.Set("X-API-Key", credential)
	case "bearer":
		request.Header.Set("Authorization", "Bearer "+credential)
	}
	response := httptest.NewRecorder()
	h.engine.ServeHTTP(response, request)
	return response.Code, response.Body.Bytes()
}

func TestScopedAgentKeyEndToEnd(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	h := &agentHarness{t: t, db: db, engine: Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true})}

	newUser := func(label string) (id, bearer string) {
		if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', $2) RETURNING id`,
			uuid.NewString()+"@example.com", label).Scan(&id); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, id) })
		pair, err := db.CreateFirstPartySession(ctx, id, "web", label)
		if err != nil {
			t.Fatal(err)
		}
		return id, pair.AccessToken
	}
	ownerID, ownerBearer := newUser("Owner")
	otherID, _ := newUser("Other")

	insertAudio := func(userID, name string, created time.Time) string {
		var id string
		if err := db.QueryRowContext(ctx, `
			INSERT INTO audio_transcriptions (filename, original_name, status, transcript_text, word_count, user_id, created_at)
			VALUES ('f.m4a', $1, 'completed', 'hello world transcript body', 4, $2, $3) RETURNING id`,
			name, userID, created).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	oldItem := insertAudio(ownerID, "Standup notes", time.Now().Add(-72*time.Hour))
	newItem := insertAudio(ownerID, "Voice memo 12", time.Now().Add(-time.Hour))
	foreignItem := insertAudio(otherID, "Someone else's memo", time.Now())

	createKey := func(body string) (status int, key models.CreateAPIKeyResponse) {
		code, raw := h.do("POST", "/api/v1/user/keys", "bearer", ownerBearer, body)
		if code == http.StatusCreated {
			if err := json.Unmarshal(raw, &key); err != nil {
				t.Fatal(err)
			}
		}
		return code, key
	}

	// Creation: validated scopes, raw key once, hashed at rest, higher rate limit.
	if code, _ := createKey(`{"name":"Bad","scopes":["library:read","superuser"]}`); code != http.StatusBadRequest {
		t.Fatalf("unknown scope status = %d, want 400", code)
	}
	code, agent := createKey(`{"name":"Brain Dump agent","scopes":["library:read","library:write"]}`)
	if code != http.StatusCreated || agent.RawKey == "" || strings.Join(agent.Scopes, ",") != "library:read,library:write" || agent.RateLimit != models.ScopedKeyRateLimit {
		t.Fatalf("scoped key create = %d %#v", code, agent)
	}
	var storedHash string
	if err := db.GetContext(ctx, &storedHash, `SELECT key_hash FROM api_keys WHERE id = $1`, agent.ID); err != nil {
		t.Fatal(err)
	}
	if storedHash == agent.RawKey || storedHash != middleware.HashAPIKey(agent.RawKey) {
		t.Fatal("scoped key must be stored as a hash only")
	}
	_, classic := createKey(`{"name":"Classic"}`)
	if len(classic.Scopes) != 0 || classic.RateLimit != 100 {
		t.Fatalf("classic key changed: %#v", classic)
	}
	_, listBody := h.do("GET", "/api/v1/keys", "bearer", ownerBearer, "")
	if bytes.Contains(listBody, []byte(agent.RawKey)) || !bytes.Contains(listBody, []byte(`"scopes":["library:read","library:write"]`)) {
		t.Fatalf("key list leaks the raw key or omits scopes: %s", listBody)
	}

	// Done-when scenario: find an item it did not create, rename it, file it.
	code, body := h.do("GET", "/api/v1/library/items?search=Voice", "key", agent.RawKey, "")
	if code != http.StatusOK || !bytes.Contains(body, []byte(newItem)) || bytes.Contains(body, []byte(foreignItem)) {
		t.Fatalf("scoped library search = %d %s", code, body)
	}
	code, body = h.do("GET", "/api/v1/library/items?since="+time.Now().Add(-24*time.Hour).UTC().Format(time.RFC3339), "key", agent.RawKey, "")
	if code != http.StatusOK || !bytes.Contains(body, []byte(newItem)) || bytes.Contains(body, []byte(oldItem)) {
		t.Fatalf("since filter = %d %s", code, body)
	}
	if code, _ = h.do("GET", "/api/v1/library/items?since=yesterday", "key", agent.RawKey, ""); code != http.StatusBadRequest {
		t.Fatalf("bad since = %d, want 400", code)
	}
	if code, _ = h.do("PATCH", "/api/v1/audio/transcriptions/"+newItem, "key", agent.RawKey, `{"name":"Call with landlord"}`); code != http.StatusOK {
		t.Fatalf("rename = %d", code)
	}
	if code, _ = h.do("PATCH", "/api/v1/audio/transcriptions/"+foreignItem, "key", agent.RawKey, `{"name":"nope"}`); code != http.StatusNotFound {
		t.Fatalf("renaming another account's item = %d, want 404", code)
	}
	code, body = h.do("POST", "/api/v1/collections", "key", agent.RawKey, `{"name":"Brain Dump"}`)
	var collection models.Collection
	if code != http.StatusCreated || json.Unmarshal(body, &collection) != nil || collection.ID == "" {
		t.Fatalf("create collection = %d %s", code, body)
	}
	code, body = h.do("POST", "/api/v1/collections/"+collection.ID+"/items", "key", agent.RawKey,
		`{"items":[{"item_type":"audio","item_id":"`+newItem+`"}]}`)
	if code != http.StatusOK && code != http.StatusCreated {
		t.Fatalf("add to collection = %d %s", code, body)
	}

	// The change is visible to the signed-in user in the web library.
	code, body = h.do("GET", "/api/v1/library/items", "bearer", ownerBearer, "")
	if code != http.StatusOK || !bytes.Contains(body, []byte("Call with landlord")) {
		t.Fatalf("owner library after rename = %d %s", code, body)
	}
	code, body = h.do("GET", "/api/v1/collections/"+collection.ID, "bearer", ownerBearer, "")
	if code != http.StatusOK || !bytes.Contains(body, []byte(newItem)) {
		t.Fatalf("owner collection = %d %s", code, body)
	}

	// Forbidden routes: out-of-scope delete and every account-level route.
	forbidden := []struct{ method, path, body string }{
		{"DELETE", "/api/v1/audio/transcriptions/" + newItem, ""},
		{"GET", "/api/v1/keys", ""},
		{"POST", "/api/v1/user/keys", `{"name":"escalate","scopes":["library:delete"]}`},
		{"DELETE", "/api/v1/keys/" + agent.ID, ""},
		{"GET", "/api/v1/webhooks", ""},
		{"GET", "/api/v1/ops/audio/health", ""},
		{"GET", "/api/v1/user/agent-activity", ""},
		{"POST", "/api/v1/ai-content-reports", `{}`},
	}
	for _, tc := range forbidden {
		if code, _ = h.do(tc.method, tc.path, "key", agent.RawKey, tc.body); code != http.StatusForbidden {
			t.Errorf("scoped key %s %s = %d, want 403", tc.method, tc.path, code)
		}
	}
	if code, _ = h.do("GET", "/api/v1/auth/me", "key", agent.RawKey, ""); code != http.StatusUnauthorized {
		t.Errorf("scoped key on /auth/me = %d, want 401", code)
	}
	var itemStillThere int
	if err := db.GetContext(ctx, &itemStillThere, `SELECT COUNT(*) FROM audio_transcriptions WHERE id = $1`, newItem); err != nil || itemStillThere != 1 {
		t.Fatalf("denied delete removed the item: %d %v", itemStillThere, err)
	}

	// Classic keys keep exact-key reads: the user's items stay invisible.
	code, body = h.do("GET", "/api/v1/library/items", "key", classic.RawKey, "")
	if code != http.StatusOK || bytes.Contains(body, []byte(newItem)) {
		t.Fatalf("classic key read scope changed: %d %s", code, body)
	}

	// Activity: writes and denials recorded, reads and content absent.
	code, body = h.do("GET", "/api/v1/user/agent-activity", "bearer", ownerBearer, "")
	if code != http.StatusOK {
		t.Fatalf("activity = %d %s", code, body)
	}
	var activity []models.AgentActivity
	if err := json.Unmarshal(body, &activity); err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	for _, row := range activity {
		if row.APIKeyName != "Brain Dump agent" {
			t.Errorf("activity row for unexpected key: %#v", row)
		}
		found[row.Method+" "+row.Route+" "+row.ItemID+" "+http.StatusText(row.StatusCode)] = true
	}
	for _, want := range []string{
		"PATCH /api/v1/audio/transcriptions/:id " + newItem + " OK",
		"PATCH /api/v1/audio/transcriptions/:id " + foreignItem + " Not Found",
		"POST /api/v1/collections " + collection.ID + " Created",
		"DELETE /api/v1/audio/transcriptions/:id " + newItem + " Forbidden",
	} {
		if !found[want] {
			t.Errorf("activity is missing %q; got %v", want, found)
		}
	}
	for _, secret := range []string{"Call with landlord", "hello world", "Brain Dump\"", "Voice"} {
		if bytes.Contains(body, []byte(secret)) {
			t.Errorf("activity response contains content %q: %s", secret, body)
		}
	}
	var stored int
	if err := db.GetContext(ctx, &stored, `SELECT COUNT(*) FROM agent_activity WHERE user_id = $1 AND method = 'GET' AND status_code < 400`, ownerID); err != nil || stored != 0 {
		t.Fatalf("successful reads must not be logged: %d %v", stored, err)
	}
	var other int
	if err := db.GetContext(ctx, &other, `SELECT COUNT(*) FROM agent_activity WHERE user_id = $1`, otherID); err != nil || other != 0 {
		t.Fatalf("activity leaked to another account: %d %v", other, err)
	}

	// A capture-only key reaches upload routes and nothing else.
	_, upload := createKey(`{"name":"Share extension","scopes":["capture:upload"]}`)
	if code, _ = h.do("GET", "/api/v1/library/items", "key", upload.RawKey, ""); code != http.StatusForbidden {
		t.Errorf("capture key read library = %d, want 403", code)
	}
	if code, _ = h.do("PATCH", "/api/v1/audio/transcriptions/"+newItem, "key", upload.RawKey, `{"name":"x"}`); code != http.StatusForbidden {
		t.Errorf("capture key rename = %d, want 403", code)
	}
	if code, _ = h.do("POST", "/api/v1/audio/uploads/presign", "key", upload.RawKey, `{}`); code == http.StatusForbidden || code == http.StatusUnauthorized {
		t.Errorf("capture key presign = %d, want scope to allow it", code)
	}

	// Revocation takes effect immediately.
	if code, _ = h.do("DELETE", "/api/v1/keys/"+agent.ID, "bearer", ownerBearer, ""); code != http.StatusOK {
		t.Fatalf("revoke = %d", code)
	}
	if code, _ = h.do("GET", "/api/v1/library/items", "key", agent.RawKey, ""); code != http.StatusUnauthorized {
		t.Fatalf("revoked key = %d, want 401", code)
	}
}
