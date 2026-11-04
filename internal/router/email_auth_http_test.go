package router

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcript"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	accountservice "github.com/Shimizu-Technology/media-tools-api/internal/services/account"
	emailservice "github.com/Shimizu-Technology/media-tools-api/internal/services/email"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type authTestTransport func(*http.Request) (*http.Response, error)

func (f authTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func unbreachedTestChecker() *accountservice.PwnedChecker {
	return &accountservice.PwnedChecker{Client: &http.Client{Transport: authTestTransport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}}
}

type authHTTPFixture struct {
	db     *database.DB
	email  *emailservice.Service
	server *httptest.Server
	engine *gin.Engine
	t      *testing.T
}

func newAuthHTTPFixture(t *testing.T, signup bool, services ...*summary.Service) *authHTTPFixture {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(url)
	if err != nil {
		t.Fatal("connect local auth database")
	}
	t.Cleanup(func() { _ = db.Close() })
	if err = db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	email, err := emailservice.New("log", "", "", "synthetic-http-test-secret")
	if err != nil {
		t.Fatal(err)
	}
	var summarizer *summary.Service
	if len(services) > 0 {
		summarizer = services[0]
	}
	engine := Setup(RouterConfig{Summarizer: summarizer, DB: db, FirstPartyAuthEnabled: true, FirstPartyPasswordAuthEnabled: true, WebCookieAuthEnabled: true, PublicSignupEnabled: signup, Email: email, Pwned: unbreachedTestChecker(), AllowedOrigins: []string{"https://media.example.test"}, DefaultMonthlyTranscriptionMinutes: 2, DefaultMonthlyAIRequests: 2})
	fixture := &authHTTPFixture{db: db, email: email, engine: engine, t: t}
	// This hook exists ONLY in a _test.go file. It cannot be compiled into
	// cmd/server or any release binary, irrespective of environment variables.
	// Keep raw codes in memory; neither the test report nor log delivery prints them.
	engine.POST("/__test/email-code", func(c *gin.Context) {
		var req struct {
			Email   string `json:"email"`
			Purpose string `json:"purpose"`
		}
		if err := c.ShouldBindJSON(&req); err != nil {
			c.Status(400)
			return
		}
		var sealed string
		if err := db.GetContext(c.Request.Context(), &sealed, `SELECT o.sealed FROM auth_email_outbox o JOIN auth_email_challenges ch ON ch.id=o.challenge_id WHERE ch.email=$1 AND ch.purpose=$2`, req.Email, req.Purpose); err != nil {
			c.Status(404)
			return
		}
		message, err := email.Open(sealed)
		if err != nil {
			c.Status(500)
			return
		}
		matches := regexp.MustCompile(`code is ([0-9]{6})`).FindStringSubmatch(message.Text)
		if len(matches) != 2 {
			c.Status(500)
			return
		}
		c.JSON(200, gin.H{"code": matches[1]})
	})
	fixture.server = httptest.NewServer(engine)
	t.Cleanup(fixture.server.Close)
	if session := os.Getenv("AUTH_QA_LIFECYCLE_SESSION"); session != "" {
		// The test executable owns the ephemeral HTTP listener and closes it before
		// exit. The outer agent cleans its lifecycle record after the process exits.
		if output, err := exec.Command("dev-lifecycle", "claim", "--session", session, "--reason", "auth HTTP acceptance server", "process", strconv.Itoa(os.Getpid())).CombinedOutput(); err != nil {
			t.Fatalf("claim HTTP test process: %s", output)
		}
	}
	return fixture
}
func (f *authHTTPFixture) request(method, path string, body any, bearer string, want int) []byte {
	f.t.Helper()
	raw, _ := json.Marshal(body)
	req, err := http.NewRequest(method, f.server.URL+path, bytes.NewReader(raw))
	if err != nil {
		f.t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		f.t.Fatal("HTTP request failed")
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	if err != nil {
		f.t.Fatal(err)
	}
	if resp.StatusCode != want {
		var public struct{ Error string }
		_ = json.Unmarshal(out, &public)
		f.t.Fatalf("%s %s status %d want %d error=%s", method, path, resp.StatusCode, want, public.Error)
	}
	return out
}
func (f *authHTTPFixture) code(email, purpose string) string {
	f.t.Helper()
	raw := f.request("POST", "/__test/email-code", gin.H{"email": email, "purpose": purpose}, "", 200)
	var out struct{ Code string }
	if err := json.Unmarshal(raw, &out); err != nil {
		f.t.Fatal(err)
	}
	return out.Code
}
func (f *authHTTPFixture) cleanupEmail(email string) {
	f.t.Cleanup(func() {
		_, _ = f.db.ExecContext(context.Background(), `DELETE FROM users WHERE lower(email)=$1`, email)
		_, _ = f.db.ExecContext(context.Background(), `DELETE FROM auth_email_challenges WHERE email=$1`, email)
		_, _ = f.db.ExecContext(context.Background(), `DELETE FROM auth_email_limits WHERE email=$1`, email)
	})
}
func (f *authHTTPFixture) signup(email, password string) {
	f.t.Helper()
	f.cleanupEmail(email)
	f.request("POST", "/api/v1/auth/signup", gin.H{"email": email, "password": password, "name": "HTTP Auth"}, "", 202)
	f.request("POST", "/api/v1/auth/signup/verify", gin.H{"email": email, "code": f.code(email, "signup"), "password": password}, "", 200)
}
func (f *authHTTPFixture) login(email, password string) *database.AuthTokenPair {
	f.t.Helper()
	next, _ := database.RandomFirstPartyRefreshToken()
	raw := f.request("POST", "/api/v1/auth/password/login", gin.H{"email": email, "password": password, "client_type": "ios", "next_refresh_token": next}, "", 201)
	var pair database.AuthTokenPair
	if err := json.Unmarshal(raw, &pair); err != nil {
		f.t.Fatal(err)
	}
	return &pair
}
func TestAuthHTTPDefaultsEnumerationAndVerification(t *testing.T) {
	f := newAuthHTTPFixture(t, false)
	email := uuid.NewString() + "@example.invalid"
	password := "a synthetic twelve plus password"
	f.cleanupEmail(email)
	f.request("POST", "/api/v1/auth/signup", gin.H{"email": email, "password": password}, "", 403)
	f = newAuthHTTPFixture(t, true)
	first := f.request("POST", "/api/v1/auth/signup", gin.H{"email": email, "password": password}, "", 202)
	code := f.code(email, "signup")
	again := f.request("POST", "/api/v1/auth/signup", gin.H{"email": email, "password": password}, "", 202)
	if !bytes.Equal(first, again) || code != f.code(email, "signup") {
		t.Fatal("resend throttle changed receipt or code")
	}
	f.request("POST", "/api/v1/auth/signup/verify", gin.H{"email": email, "code": code, "password": password}, "", 200)
	same := f.request("POST", "/api/v1/auth/signup", gin.H{"email": email, "password": password}, "", 202)
	if !bytes.Equal(first, same) {
		t.Fatal("signup reveals existing address")
	}
	f.request("POST", "/api/v1/auth/signup/verify", gin.H{"email": email, "code": code, "password": password}, "", 400)
	pair := f.login(email, password)
	raw := f.request("GET", "/api/v1/auth/me", nil, pair.AccessToken, 200)
	var user struct {
		EmailVerified      bool `json:"email_verified"`
		OnboardingRequired bool `json:"onboarding_required"`
	}
	_ = json.Unmarshal(raw, &user)
	if !user.EmailVerified || user.OnboardingRequired {
		t.Fatal("email/password did not complete onboarding")
	}
	known := f.request("POST", "/api/v1/auth/password/forgot", gin.H{"email": email}, "", 202)
	unknown := f.request("POST", "/api/v1/auth/password/forgot", gin.H{"email": uuid.NewString() + "@example.invalid"}, "", 202)
	if !bytes.Equal(known, unknown) {
		t.Fatal("forgot response enumerates accounts")
	}
	t.Log("D01/D02 passed via local HTTP: defaults, enumeration, throttle, verification, login, optional passkeys")
}
func TestAuthHTTPPasswordlessResetChangesAndDeletion(t *testing.T) {
	f := newAuthHTTPFixture(t, true)
	ctx := context.Background()
	email := uuid.NewString() + "@example.invalid"
	f.cleanupEmail(email)
	var userID string
	if err := f.db.QueryRowContext(ctx, `INSERT INTO users(email,password_hash,name,clerk_id) VALUES($1,'','Passwordless HTTP',$2) RETURNING id`, email, "synthetic_clerk_"+uuid.NewString()).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	old, err := f.db.CreateFirstPartySession(ctx, userID, "ios", "Before reset")
	if err != nil {
		t.Fatal(err)
	}
	password := "a synthetic first password for HTTP"
	f.request("POST", "/api/v1/auth/password/forgot", gin.H{"email": email}, "", 202)
	f.request("POST", "/api/v1/auth/password/reset", gin.H{"email": email, "code": f.code(email, "reset"), "password": password}, "", 200)
	if _, _, err := f.db.GetUserByFirstPartyAccessToken(ctx, old.AccessToken); err == nil {
		t.Fatal("reset did not revoke old session")
	}
	pair := f.login(email, password)
	other := f.login(email, password)
	replacement := "another synthetic HTTP password"
	f.request("POST", "/api/v1/auth/password", gin.H{"password": replacement}, pair.AccessToken, 401)
	f.request("POST", "/api/v1/auth/password", gin.H{"password": replacement, "current_password": password}, pair.AccessToken, 200)
	if _, _, err := f.db.GetUserByFirstPartyAccessToken(ctx, other.AccessToken); err == nil {
		t.Fatal("other session survived password change")
	}
	f.request("GET", "/api/v1/auth/me", nil, pair.AccessToken, 200)
	newEmail := uuid.NewString() + "@example.invalid"
	f.cleanupEmail(newEmail)
	f.request("POST", "/api/v1/auth/email/change", gin.H{"email": newEmail, "current_password": "wrong"}, pair.AccessToken, 401)
	f.request("POST", "/api/v1/auth/email/change", gin.H{"email": newEmail, "current_password": replacement}, pair.AccessToken, 202)
	f.request("POST", "/api/v1/auth/email/change/verify", gin.H{"email": newEmail, "code": f.code(newEmail, "email_change")}, pair.AccessToken, 200)
	f.request("GET", "/api/v1/auth/me", nil, pair.AccessToken, 401)
	pair = f.login(newEmail, replacement)
	// Preserve the real Clerk link through reset and email change; deletion is
	// tested after local detachment to avoid any provider calls.
	var clerk *string
	if err := f.db.GetContext(ctx, &clerk, `SELECT clerk_id FROM users WHERE id=$1`, userID); err != nil || clerk == nil {
		t.Fatal("Clerk migration link lost")
	}
	if _, err = f.db.ExecContext(ctx, `UPDATE users SET clerk_id=NULL WHERE id=$1`, userID); err != nil {
		t.Fatal(err)
	}
	f.request("DELETE", "/api/v1/account", gin.H{"confirmation": "DELETE"}, pair.AccessToken, 401)
	var notices int
	if err := f.db.GetContext(ctx, &notices, `SELECT COUNT(*) FROM auth_email_outbox WHERE user_id=$1 AND challenge_id IS NULL`, userID); err != nil || notices != 3 {
		t.Fatalf("expected reset/password/email notices, count=%d", notices)
	}
	f.request("DELETE", "/api/v1/account", gin.H{"confirmation": "DELETE", "current_password": replacement}, pair.AccessToken, 202)
	var exists bool
	_ = f.db.GetContext(ctx, &exists, `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1)`, userID)
	if exists {
		t.Fatal("deletion did not persist")
	}
	t.Log("D04/D05 passed via local HTTP: passwordless Clerk account reset, session revocation, password/email reauthentication, notices, deletion")
}
func TestAuthHTTPUsageAndOwnerExemption(t *testing.T) {
	f := newAuthHTTPFixture(t, true)
	email := uuid.NewString() + "@example.invalid"
	password := "usage fixture synthetic password"
	f.signup(email, password)
	pair := f.login(email, password)
	raw := f.request("GET", "/api/v1/auth/usage", nil, pair.AccessToken, 200)
	var usage database.Usage
	_ = json.Unmarshal(raw, &usage)
	if usage.TranscriptionLimitSeconds != 120 || usage.AIRequestLimit != 2 || usage.Exempt {
		t.Fatal("wrong caps")
	}
	// Queue and complete two real HTTP video requests through a local worker.
	// The extractor is synthetic; no provider is contacted or billed.
	pool := worker.NewPool(1, 10, f.db, quotaHTTPExtractor{}, nil)
	pool.SetEmailService(f.email)
	pool.Start()
	t.Cleanup(pool.Stop)
	workingEngine := Setup(RouterConfig{DB: f.db, WorkerPool: pool, FirstPartyAuthEnabled: true, FirstPartyPasswordAuthEnabled: true, Email: f.email, Pwned: unbreachedTestChecker(), DefaultMonthlyTranscriptionMinutes: 2, DefaultMonthlyAIRequests: 2})
	workingServer := httptest.NewServer(workingEngine)
	t.Cleanup(workingServer.Close)
	f.server = workingServer
	for _, video := range []string{"dQw4w9WgXcQ", "jNQXAC9IVRw"} {
		raw := f.request("POST", "/api/v1/transcripts", gin.H{"url": "https://youtube.com/watch?v=" + video}, pair.AccessToken, 202)
		var item struct{ ID string }
		_ = json.Unmarshal(raw, &item)
		deadline := time.Now().Add(10 * time.Second)
		for {
			result := f.request("GET", "/api/v1/transcripts/"+item.ID, nil, pair.AccessToken, 200)
			var state struct{ Status string }
			_ = json.Unmarshal(result, &state)
			if state.Status == "completed" {
				break
			}
			if state.Status == "failed" || time.Now().After(deadline) {
				t.Fatal("accepted quota fixture did not complete")
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	if _, err := f.db.ReserveAIRequest(context.Background(), pair.UserID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.ReserveAIRequest(context.Background(), pair.UserID); err != nil {
		t.Fatal(err)
	}
	raw = f.request("GET", "/api/v1/auth/usage", nil, pair.AccessToken, 200)
	_ = json.Unmarshal(raw, &usage)
	if usage.TranscriptionSeconds != 120 || usage.AIRequests != 2 {
		t.Fatal("HTTP work did not persist monthly usage")
	}

	f.request("POST", "/api/v1/transcripts", gin.H{"url": "https://youtube.com/watch?v=dQw4w9WgXcQ"}, pair.AccessToken, 200)
	f.request("POST", "/api/v1/transcripts", gin.H{"url": "https://youtube.com/watch?v=abcdefghijk"}, pair.AccessToken, 402)
	f.request("POST", "/api/v1/summaries", gin.H{}, pair.AccessToken, 402)
	f.request("POST", "/api/v1/audio/transcriptions/"+uuid.NewString()+"/chat", gin.H{}, pair.AccessToken, 402)
	// Agent keys share the account balance, and cannot use auth routes to
	// change that account's credentials or quota boundary.
	keyResponse := f.request("POST", "/api/v1/user/keys", gin.H{"name": "Quota fixture agent", "scopes": []string{"library:write"}}, pair.AccessToken, 201)
	var key struct {
		Key string `json:"raw_key"`
	}
	if err := json.Unmarshal(keyResponse, &key); err != nil || key.Key == "" {
		t.Fatal("scoped key issuance failed")
	}
	for _, tc := range []struct {
		path string
		want int
	}{{"/api/v1/transcripts", 402}, {"/api/v1/summaries", 402}, {"/api/v1/auth/password", 401}} {
		req, err := http.NewRequest("POST", f.server.URL+tc.path, strings.NewReader(`{"url":"https://youtube.com/watch?v=abcdefghijk"}`))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-API-Key", key.Key)
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal("scoped key HTTP request failed")
		}
		_, _ = io.Copy(io.Discard, response.Body)
		_ = response.Body.Close()
		if response.StatusCode != tc.want {
			t.Fatalf("scoped key %s status=%d want=%d", tc.path, response.StatusCode, tc.want)
		}
	}
	owner := Setup(RouterConfig{DB: f.db, FirstPartyAuthEnabled: true, FirstPartyPasswordAuthEnabled: true, Email: f.email, OwnerUserID: pair.UserID, Pwned: unbreachedTestChecker()})
	next := httptest.NewServer(owner)
	defer next.Close()
	previous := f.server
	f.server = next
	defer func() { f.server = previous }()
	raw = f.request("GET", "/api/v1/auth/usage", nil, pair.AccessToken, 200)
	_ = json.Unmarshal(raw, &usage)
	if !usage.Exempt {
		t.Fatal("owner not exempt")
	}
	// Invalid input reaches validation for the owner, proving the 402 guard was
	// bypassed without sending media to a paid provider.
	f.request("POST", "/api/v1/transcripts", gin.H{}, pair.AccessToken, 400)
	t.Log("D09 passed via local HTTP: exposed limits, transcription/summary/chat 402 and owner exemption")
}

func TestAuthHTTPVerificationExpiryAttemptsAndResend(t *testing.T) {
	f := newAuthHTTPFixture(t, true)
	email := uuid.NewString() + "@example.invalid"
	f.cleanupEmail(email)
	password := "attempt fixture synthetic password"
	begin := func() { f.request("POST", "/api/v1/auth/signup", gin.H{"email": email, "password": password}, "", 202) }
	begin()
	var previousID string
	if err := f.db.GetContext(context.Background(), &previousID, `SELECT id FROM auth_email_challenges WHERE email=$1 AND purpose='signup'`, email); err != nil {
		t.Fatal(err)
	}
	code := f.code(email, "signup")
	wrong := "000000"
	if code == wrong {
		wrong = "999999"
	}
	for i := 0; i < 5; i++ {
		f.request("POST", "/api/v1/auth/signup/verify", gin.H{"email": email, "code": wrong, "password": password}, "", 400)
	}
	f.request("POST", "/api/v1/auth/signup/verify", gin.H{"email": email, "code": code, "password": password}, "", 400)
	if _, err := f.db.ExecContext(context.Background(), `UPDATE auth_email_limits SET created_at=NOW()-INTERVAL '61 seconds' WHERE email=$1 AND kind='send'`, email); err != nil {
		t.Fatal(err)
	}
	begin()
	newCode := f.code(email, "signup")
	var previousExists bool
	if err := f.db.GetContext(context.Background(), &previousExists, `SELECT EXISTS(SELECT 1 FROM auth_email_challenges WHERE id=$1)`, previousID); err != nil || previousExists {
		t.Fatal("resend retained the previous challenge")
	}
	// Uniform six-digit codes can coincide. Always assert challenge replacement;
	// check rejection of the old digits only when the new digits differ.
	if newCode != code {
		f.request("POST", "/api/v1/auth/signup/verify", gin.H{"email": email, "code": code, "password": password}, "", 400)
	}
	if _, err := f.db.ExecContext(context.Background(), `UPDATE auth_email_challenges SET expires_at=NOW()-INTERVAL '1 second' WHERE email=$1`, email); err != nil {
		t.Fatal(err)
	}
	f.request("POST", "/api/v1/auth/signup/verify", gin.H{"email": email, "code": newCode, "password": password}, "", 400)
	t.Log("D03 passed via local HTTP: five attempts, replacement invalidation, expiry")
}

func TestAuthHTTPFailedGuessesDoNotLockCorrectPassword(t *testing.T) {
	f := newAuthHTTPFixture(t, true)
	email := uuid.NewString() + "@example.invalid"
	password := "lockout fixture synthetic password"
	f.signup(email, password)
	next, _ := database.RandomFirstPartyRefreshToken()
	request := gin.H{"email": email, "password": "wrong", "client_type": "ios", "next_refresh_token": next}
	for i := 0; i < 11; i++ {
		want := 401
		if i == 10 {
			want = 429
		}
		f.request("POST", "/api/v1/auth/password/login", request, "", want)
	}
	f.login(email, password)
	t.Log("D06 passed: account failures throttle wrong guesses, correct password remains usable")
}

func TestAuthHTTPBrowserCSRFAndStalePendingRecovery(t *testing.T) {
	f := newAuthHTTPFixture(t, true)
	email := uuid.NewString() + "@example.invalid"
	password := "browser fixture synthetic password"
	f.signup(email, password)
	const origin = "https://media.example.test"
	prepare := postWebRecovery(t, f.engine, "/api/v1/auth/web/session/password/prepare", gin.H{}, nil, origin, "")
	pending := cookieByName(prepare.Result().Cookies(), middleware.WebPasswordPendingCookie)
	csrf := cookieByName(prepare.Result().Cookies(), middleware.WebCSRFCookie)
	if pending == nil || csrf == nil {
		t.Fatal("prepare missing cookies")
	}
	finish := postWebRecovery(t, f.engine, "/api/v1/auth/web/session/password/finish", gin.H{"email": email, "password": password}, []*http.Cookie{pending, csrf}, origin, csrf.Value)
	if finish.Code != 201 {
		t.Fatal("browser password finish failed")
	}
	access := cookieByName(finish.Result().Cookies(), middleware.WebAccessCookie)
	refresh := cookieByName(finish.Result().Cookies(), middleware.WebRefreshCookie)
	csrf = cookieByName(finish.Result().Cookies(), middleware.WebCSRFCookie)
	prep := postWebRecovery(t, f.engine, "/api/v1/auth/web/session/prepare", gin.H{}, []*http.Cookie{access, refresh, csrf}, origin, csrf.Value)
	successor := cookieByName(prep.Result().Cookies(), middleware.WebPendingCookie)
	if successor == nil {
		t.Fatal("refresh prepare missing successor")
	}
	rotated := postWebRecovery(t, f.engine, "/api/v1/auth/web/session/refresh", gin.H{}, []*http.Cookie{access, refresh, csrf, successor}, origin, csrf.Value)
	renewed := cookieByName(rotated.Result().Cookies(), middleware.WebCSRFCookie)
	if rotated.Code != 200 || renewed == nil || renewed.MaxAge != 365*24*60*60 || renewed.Value != csrf.Value {
		t.Fatal("refresh did not renew stable CSRF secret")
	}
	owner, sessionID, err := f.db.GetUserByFirstPartyRefreshToken(context.Background(), refresh.Value)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.RevokeFirstPartySession(context.Background(), owner.ID, sessionID); err != nil {
		t.Fatal(err)
	}
	stale := postWebRecovery(t, f.engine, "/api/v1/auth/web/session/password/finish", gin.H{"email": email, "password": password}, []*http.Cookie{pending, csrf}, origin, csrf.Value)
	var cleared *http.Cookie
	for _, cookie := range stale.Result().Cookies() {
		if cookie.Name == middleware.WebPasswordPendingCookie {
			cleared = cookie
		}
	}
	if stale.Code != 400 || cleared == nil || cleared.MaxAge >= 0 {
		t.Fatal("stale pending did not return recoverable 400 and clear cookie")
	}
	preparedAgain := postWebRecovery(t, f.engine, "/api/v1/auth/web/session/password/prepare", gin.H{}, []*http.Cookie{csrf}, origin, "")
	pending = cookieByName(preparedAgain.Result().Cookies(), middleware.WebPasswordPendingCookie)
	csrf = cookieByName(preparedAgain.Result().Cookies(), middleware.WebCSRFCookie)
	recovered := postWebRecovery(t, f.engine, "/api/v1/auth/web/session/password/finish", gin.H{"email": email, "password": password}, []*http.Cookie{pending, csrf}, origin, csrf.Value)
	if recovered.Code != 201 {
		t.Fatal("fresh preparation did not recover stale sign-in")
	}
	t.Log("D07 passed: CSRF renewed on refresh; stale pending cleared and sign-in recovered")
}

// A deterministic source keeps this acceptance run local and free of provider sends.
type quotaHTTPExtractor struct{}

func (quotaHTTPExtractor) ExtractFromURL(context.Context, string, string) (*transcript.Result, error) {
	return &transcript.Result{Duration: 60, Title: "Quota fixture", Language: "en", Transcript: "Local quota acceptance transcript.", WordCount: 4}, nil
}
