package router

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

func TestAuthHTTPSignupPasswordBelongsToEmailProver(t *testing.T) {
	f := newAuthHTTPFixture(t, true)
	email := uuid.NewString() + "@example.invalid"
	f.cleanupEmail(email)
	// A stranger may trigger a code, but their chosen password must never persist.
	f.request("POST", "/api/v1/auth/signup", gin.H{"email": email, "password": "attacker chosen synthetic password"}, "", 202)
	var pendingHash string
	if err := f.db.Get(&pendingHash, `SELECT password_hash FROM auth_email_challenges WHERE email=$1`, email); err != nil || pendingHash != "" {
		t.Fatal("signup stored a password before proof", err)
	}
	code := f.code(email, "signup")
	f.request("POST", "/api/v1/auth/signup/verify", gin.H{"email": email, "code": code}, "", 400)
	chosen := "email owner chosen synthetic password"
	f.request("POST", "/api/v1/auth/signup/verify", gin.H{"email": email, "code": code, "password": chosen}, "", 200)
	f.login(email, chosen)
	next, _ := database.RandomFirstPartyRefreshToken()
	f.request("POST", "/api/v1/auth/password/login", gin.H{"email": email, "password": "attacker chosen synthetic password", "client_type": "ios", "next_refresh_token": next}, "", 401)
	// New contract: initiation takes only email and optional name.
	another := uuid.NewString() + "@example.invalid"
	f.cleanupEmail(another)
	f.request("POST", "/api/v1/auth/signup", gin.H{"email": another, "name": "Verified owner"}, "", 202)
	f.request("POST", "/api/v1/auth/signup/verify", gin.H{"email": another, "code": f.code(another, "signup"), "password": chosen}, "", 200)
	f.login(another, chosen)
}

func TestAuthHTTPFirstPasswordRequiresVerifiedStoredEmail(t *testing.T) {
	f := newAuthHTTPFixture(t, true)
	email := uuid.NewString() + "@example.invalid"
	f.cleanupEmail(email)
	var userID string
	if err := f.db.QueryRow(`INSERT INTO users(email,password_hash) VALUES($1,'') RETURNING id`, email).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	pair, err := f.db.CreateFirstPartySession(context.Background(), userID, "ios", "Unverified account")
	if err != nil {
		t.Fatal(err)
	}
	raw := f.request("POST", "/api/v1/auth/password", gin.H{"password": "a synthetic first account password"}, pair.AccessToken, 403)
	if !strings.Contains(string(raw), "email_verification_required") {
		t.Fatal("unstable verification error")
	}
	var count int
	if err = f.db.Get(&count, `SELECT COUNT(*) FROM auth_password_credentials WHERE user_id=$1`, userID); err != nil || count != 0 {
		t.Fatal("stolen session installed password", err)
	}
	f.request("POST", "/api/v1/auth/email/verify", gin.H{"email": email}, pair.AccessToken, 202)
	f.request("POST", "/api/v1/auth/email/verify/confirm", gin.H{"email": email, "code": f.code(email, "verify")}, pair.AccessToken, 200)
	f.request("POST", "/api/v1/auth/password", gin.H{"password": "a synthetic first account password"}, pair.AccessToken, 200)
}

func TestAuthHTTPRecoveryRevokesClassicScopedAndCaptureKeysOnlyOnRecovery(t *testing.T) {
	f := newAuthHTTPFixture(t, true)
	email := uuid.NewString() + "@example.invalid"
	password := "synthetic recovery fixture password"
	f.signup(email, password)
	pair := f.login(email, password)
	createKeys := func() []string {
		ids := []string{}
		for _, scopes := range [][]string{nil, {"library:read", "library:write"}, {"capture:upload"}} {
			var key models.APIKey
			raw := f.request("POST", "/api/v1/user/keys", gin.H{"name": "Recovery fixture key", "scopes": scopes}, pair.AccessToken, 201)
			var response struct {
				APIKey models.APIKey `json:"api_key"`
				ID     string        `json:"id"`
			}
			_ = json.Unmarshal(raw, &key)
			_ = json.Unmarshal(raw, &response)
			id := key.ID
			if id == "" {
				id = response.APIKey.ID
			}
			if id == "" {
				id = response.ID
			}
			if id == "" {
				t.Fatal("key ID missing")
			}
			ids = append(ids, id)
		}
		return ids
	}
	assertActive := func(ids []string, want bool) {
		t.Helper()
		for _, id := range ids {
			var active bool
			if err := f.db.Get(&active, `SELECT active FROM api_keys WHERE id=$1`, id); err != nil || active != want {
				t.Fatal("API key recovery state mismatch", err)
			}
		}
	}
	keys := createKeys()
	replacement := "synthetic ordinary replacement password"
	f.request("POST", "/api/v1/auth/password", gin.H{"password": replacement, "current_password": password}, pair.AccessToken, 200)
	assertActive(keys, true)
	f.request("POST", "/api/v1/auth/password/forgot", gin.H{"email": email}, "", 202)
	f.request("POST", "/api/v1/auth/password/reset", gin.H{"email": email, "code": f.code(email, "reset"), "password": password}, "", 200)
	assertActive(keys, false)
	pair = f.login(email, password)
	keys = createKeys()
	newEmail := uuid.NewString() + "@example.invalid"
	f.cleanupEmail(newEmail)
	f.request("POST", "/api/v1/auth/email/change", gin.H{"email": newEmail, "current_password": password}, pair.AccessToken, 202)
	f.request("POST", "/api/v1/auth/email/change/verify", gin.H{"email": newEmail, "code": f.code(newEmail, "email_change")}, pair.AccessToken, 200)
	assertActive(keys, false)
	var sealed []string
	if err := f.db.Select(&sealed, `SELECT sealed FROM auth_email_outbox WHERE user_id=$1 AND challenge_id IS NULL`, pair.UserID); err != nil {
		t.Fatal(err)
	}
	revokedNotices := 0
	for _, cipher := range sealed {
		message, err := f.email.Open(cipher)
		if err != nil {
			t.Fatal("notice decode")
		}
		if strings.Contains(message.Text, "All sessions and API keys") {
			revokedNotices++
		}
	}
	if revokedNotices != 2 {
		t.Fatal("recovery notices omitted key revocation")
	}
	// Deleting the account also removes capture keys; there is no separate
	// session-bound capture-key table in main (keys currently belong to accounts).
	pair = f.login(newEmail, password)
	keys = createKeys()
	f.request("DELETE", "/api/v1/account", gin.H{"confirmation": "DELETE", "current_password": password}, pair.AccessToken, 202)
	for _, id := range keys {
		var exists bool
		if err := f.db.Get(&exists, `SELECT EXISTS(SELECT 1 FROM api_keys WHERE id=$1)`, id); err != nil || exists {
			t.Fatal("deleted account retained capture/agent key", err)
		}
	}
}

func TestAuthHTTPAccountLimitsDoNotShareProxyBucket(t *testing.T) {
	f := newAuthHTTPFixture(t, true)
	password := "synthetic independent account password"
	one, two := uuid.NewString()+"@example.invalid", uuid.NewString()+"@example.invalid"
	f.signup(one, password)
	f.signup(two, password)
	// All requests have one local proxy/socket address. They cannot exhaust a
	// global email or password bucket and deny a separate account (or correct login).
	next, _ := database.RandomFirstPartyRefreshToken()
	for i := 0; i < 35; i++ {
		want := 401
		if i >= 10 {
			want = 429
		}
		f.request("POST", "/api/v1/auth/password/login", gin.H{"email": one, "password": "wrong", "client_type": "ios", "next_refresh_token": next}, "", want)
		f.request("POST", "/api/v1/auth/password/forgot", gin.H{"email": one}, "", 202)
	}
	f.login(one, password)
	f.login(two, password)
	f.request("POST", "/api/v1/auth/password/forgot", gin.H{"email": two}, "", 202)
	if f.code(two, "reset") == "" {
		t.Fatal("shared proxy blocked other account")
	}
}

func TestAuthHTTPPaidMalformedChatStaysChargedAndModelsAreRestricted(t *testing.T) {
	original := http.DefaultTransport
	calls := 0
	http.DefaultTransport = authTestTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "openrouter.ai" {
			return original.RoundTrip(r)
		}
		calls++
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"choices":[{"message":{"content":"provider returned malformed JSON"}}]}`))}, nil
	})
	t.Cleanup(func() { http.DefaultTransport = original })
	f := newAuthHTTPFixture(t, true, summary.New("synthetic-provider-key", "openai/gpt-4o-mini"))
	email := uuid.NewString() + "@example.invalid"
	f.signup(email, "synthetic AI quota fixture password")
	pair := f.login(email, "synthetic AI quota fixture password")
	var audioID string
	if err := f.db.QueryRow(`INSERT INTO audio_transcriptions(filename,original_name,status,transcript_text,user_id) VALUES('fixture.m4a','Quota fixture','completed','The meeting agreed to ship the update on Monday.',$1) RETURNING id`, pair.UserID).Scan(&audioID); err != nil {
		t.Fatal(err)
	}
	// Validation-only failures refund; arbitrary model ids are rejected before I/O.
	raw := f.request("POST", "/api/v1/audio/transcriptions/"+audioID+"/chat", gin.H{"message": "When will it ship?", "model": "expensive/unrestricted"}, pair.AccessToken, 400)
	if !strings.Contains(string(raw), "invalid_model") || calls != 0 {
		t.Fatal("model allowlist bypassed")
	}
	for i := 0; i < 2; i++ {
		f.request("POST", "/api/v1/audio/transcriptions/"+audioID+"/chat", gin.H{"message": "When will it ship?", "model": "openai/gpt-4o-mini"}, pair.AccessToken, 500)
	}
	if calls != 2 {
		t.Fatalf("provider calls=%d want 2", calls)
	}
	f.request("POST", "/api/v1/audio/transcriptions/"+audioID+"/chat", gin.H{"message": "Try again"}, pair.AccessToken, 402)
	usage, err := f.db.AccountUsage(context.Background(), pair.UserID)
	if err != nil || usage.AIRequests != 2 {
		t.Fatal("paid parse failure refunded", err)
	}
	f.request("POST", "/api/v1/audio/transcriptions/"+audioID+"/format", gin.H{}, pair.AccessToken, 402)
}

func TestAuthHTTPOwnerModelBypassUsesExactIdentity(t *testing.T) {
	f := newAuthHTTPFixture(t, true, summary.New("synthetic-provider-key", "openai/gpt-4o-mini"))
	email := uuid.NewString() + "@example.invalid"
	password := "synthetic owner model fixture password"
	f.signup(email, password)
	pair := f.login(email, password)
	var keyID, collectionID string
	if err := f.db.QueryRow(`INSERT INTO api_keys(user_id,key_hash,key_prefix,name) VALUES($1,$2,'owner-same','Synthetic owner') RETURNING id`, pair.UserID, uuid.NewString()).Scan(&keyID); err != nil {
		t.Fatal(err)
	}
	if err := f.db.QueryRow(`INSERT INTO collections(user_id,name) VALUES($1,'Model fixture') RETURNING id`, pair.UserID).Scan(&collectionID); err != nil {
		t.Fatal(err)
	}
	var audioID string
	if err := f.db.QueryRow(`INSERT INTO audio_transcriptions(filename,original_name,status,transcript_text,user_id) VALUES('fixture.m4a','Model fixture','completed','Synthetic model fixture.',$1) RETURNING id`, pair.UserID).Scan(&audioID); err != nil {
		t.Fatal(err)
	}
	// Separate router uses the legacy prefix override; it must not unlock models
	// or quotas, while an exact key ID or owner user ID must do so account-wide.
	for _, owner := range []struct {
		user, key string
		want      int
	}{{"", "", 400}, {"", keyID, 409}, {pair.UserID, "", 409}} {
		engine := Setup(RouterConfig{DB: f.db, FirstPartyAuthEnabled: true, FirstPartyPasswordAuthEnabled: true, OwnerUserID: owner.user, OwnerKeyID: owner.key, OwnerKeyPrefix: "owner-same", Summarizer: summary.New("synthetic-provider-key", "openai/gpt-4o-mini")})
		request := httptest.NewRequest("POST", "/api/v1/collections/"+collectionID+"/chat", strings.NewReader(`{"message":"Question","model":"arbitrary/owner-model"}`))
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Authorization", "Bearer "+pair.AccessToken)
		response := httptest.NewRecorder()
		engine.ServeHTTP(response, request)
		if response.Code != owner.want {
			t.Fatalf("owner model policy status=%d want=%d", response.Code, owner.want)
		}
		// Exercise other model inputs through their actual route/bind/ownership path.
		if owner.want == 400 {
			for _, tc := range []struct{ path, body string }{{"/api/v1/summaries", `{"transcript_id":"` + uuid.NewString() + `","model":"arbitrary/model"}`}, {"/api/v1/audio/transcriptions/" + audioID + "/summarize", `{"model":"arbitrary/model"}`}} {
				req := httptest.NewRequest("POST", tc.path, strings.NewReader(tc.body))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Authorization", "Bearer "+pair.AccessToken)
				rec := httptest.NewRecorder()
				engine.ServeHTTP(rec, req)
				if rec.Code != 400 || !strings.Contains(rec.Body.String(), "invalid_model") {
					t.Fatal("model input bypassed allowlist", tc.path, rec.Code)
				}
			}
		}
	}
}

func TestAuthHTTPBrowserLostRefreshResponseThenReuse(t *testing.T) {
	f := newAuthHTTPFixture(t, true)
	email := uuid.NewString() + "@example.invalid"
	password := "synthetic browser reuse fixture password"
	f.signup(email, password)
	const origin = "https://media.example.test"
	prep := postWebRecovery(t, f.engine, "/api/v1/auth/web/session/password/prepare", gin.H{}, nil, origin, "")
	csrf := cookieByName(prep.Result().Cookies(), middleware.WebCSRFCookie)
	pending := cookieByName(prep.Result().Cookies(), middleware.WebPasswordPendingCookie)
	login := postWebRecovery(t, f.engine, "/api/v1/auth/web/session/password/finish", gin.H{"email": email, "password": password}, []*http.Cookie{csrf, pending}, origin, csrf.Value)
	if login.Code != 201 {
		t.Fatal("browser login failed")
	}
	old := cookieByName(login.Result().Cookies(), middleware.WebRefreshCookie)
	csrf = cookieByName(login.Result().Cookies(), middleware.WebCSRFCookie)
	prep = postWebRecovery(t, f.engine, "/api/v1/auth/web/session/prepare", gin.H{}, []*http.Cookie{old, csrf}, origin, csrf.Value)
	next := cookieByName(prep.Result().Cookies(), middleware.WebPendingCookie)
	rotate := func(refresh, successor *http.Cookie) *httptest.ResponseRecorder {
		return postWebRecovery(t, f.engine, "/api/v1/auth/web/session/refresh", gin.H{}, []*http.Cookie{refresh, successor, csrf}, origin, csrf.Value)
	}
	first := rotate(old, next)
	if first.Code != 200 {
		t.Fatal("first browser refresh failed")
	}
	// The browser lost all Set-Cookie values; repeat the persisted pending pair.
	retry := rotate(old, next)
	if retry.Code != 200 {
		t.Fatal("lost response did not recover")
	}
	current := cookieByName(retry.Result().Cookies(), middleware.WebRefreshCookie)
	prep = postWebRecovery(t, f.engine, "/api/v1/auth/web/session/prepare", gin.H{}, []*http.Cookie{current, csrf}, origin, csrf.Value)
	third := cookieByName(prep.Result().Cookies(), middleware.WebPendingCookie)
	latest := rotate(current, third)
	if latest.Code != 200 {
		t.Fatal("browser could not advance")
	}
	replay := rotate(old, next)
	if replay.Code != 401 {
		t.Fatal("advanced browser reuse did not revoke")
	}
	access := cookieByName(latest.Result().Cookies(), middleware.WebAccessCookie)
	if _, _, err := f.db.GetUserByFirstPartyAccessToken(context.Background(), access.Value); !errors.Is(err, database.ErrSessionInvalid) {
		t.Fatal("latest cookie survived reuse")
	}
}
