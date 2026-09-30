package router

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestRouterAppliesClerkMigrationOnlyToBearerRoutes(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.NewWithSimpleProtocol(databaseURL, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations(filepath.Join("..", "..", "migrations")); err != nil {
		t.Fatal(err)
	}

	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	const keyID = "router-migration-key"
	var issuer string
	jwks := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(middleware.JWKSet{Keys: []middleware.JWK{{
			Kid: keyID,
			Kty: "RSA",
			Alg: "RS256",
			Use: "sig",
			N:   base64.RawURLEncoding.EncodeToString(privateKey.PublicKey.N.Bytes()),
			E:   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(privateKey.PublicKey.E)).Bytes()),
		}}})
	}))
	t.Cleanup(jwks.Close)
	issuer = jwks.URL

	ctx := context.Background()
	linkedSubject := "user_" + uuid.NewString()
	unknownSubject := "user_" + uuid.NewString()
	var linkedID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', 'Router Linked') RETURNING id`, uuid.NewString()+"@example.com").Scan(&linkedID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, linkedID) })
	if err := db.EnsureAuthIdentity(ctx, linkedID, "clerk", linkedSubject); err != nil {
		t.Fatal(err)
	}

	sign := func(subject string) string {
		now := time.Now()
		token := jwt.NewWithClaims(jwt.SigningMethodRS256, middleware.ClerkClaims{RegisteredClaims: jwt.RegisteredClaims{
			Issuer: issuer, Subject: subject, IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(now.Add(time.Hour)),
		}})
		token.Header["kid"] = keyID
		signed, err := token.SignedString(privateKey)
		if err != nil {
			t.Fatal(err)
		}
		return signed
	}

	engine := Setup(RouterConfig{
		DB:                    db,
		JWTSecret:             "router-test-secret",
		ClerkJWKSURL:          jwks.URL + "/.well-known/jwks.json",
		ClerkIssuer:           issuer,
		ClerkMigrationOnly:    true,
		DefaultRateLimit:      100,
		FirstPartyAuthEnabled: true,
		WebCookieAuthEnabled:  false,
	})

	request := func(path, token string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		engine.ServeHTTP(response, req)
		return response
	}

	linked := request("/api/v1/auth/me", sign(linkedSubject))
	if linked.Code != http.StatusOK {
		t.Fatalf("linked /auth/me status = %d: %s", linked.Code, linked.Body.String())
	}
	var user models.User
	if err := json.Unmarshal(linked.Body.Bytes(), &user); err != nil || user.ID != linkedID {
		t.Fatalf("linked user = %#v, %v", user, err)
	}

	nextRefresh, err := database.RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	bootstrap := httptest.NewRequest(http.MethodPost, "/api/v1/auth/session/bootstrap", strings.NewReader(`{"client_type":"ios","device_name":"Migration Test","next_refresh_token":"`+nextRefresh+`"}`))
	bootstrap.Header.Set("Authorization", "Bearer "+sign(linkedSubject))
	bootstrap.Header.Set("Content-Type", "application/json")
	bootstrapResponse := httptest.NewRecorder()
	engine.ServeHTTP(bootstrapResponse, bootstrap)
	if bootstrapResponse.Code != http.StatusCreated {
		t.Fatalf("linked bootstrap status = %d: %s", bootstrapResponse.Code, bootstrapResponse.Body.String())
	}
	var pair database.AuthTokenPair
	if err := json.Unmarshal(bootstrapResponse.Body.Bytes(), &pair); err != nil || pair.UserID != linkedID || pair.RefreshToken != nextRefresh {
		t.Fatalf("linked bootstrap pair = %#v, %v", pair, err)
	}

	for _, path := range []string{"/api/v1/auth/me", "/api/v1/transcripts"} {
		unknown := request(path, sign(unknownSubject))
		if unknown.Code != http.StatusUnauthorized {
			t.Fatalf("unknown %s status = %d: %s", path, unknown.Code, unknown.Body.String())
		}
		var body models.ErrorResponse
		if err := json.Unmarshal(unknown.Body.Bytes(), &body); err != nil || body.Error != "unauthorized" || body.Message != "Failed to verify user identity" {
			t.Fatalf("unknown %s body = %#v, %v", path, body, err)
		}
	}

	var users, identities int
	if err := db.GetContext(ctx, &users, `SELECT COUNT(*) FROM users WHERE clerk_id = $1`, unknownSubject); err != nil {
		t.Fatal(err)
	}
	if err := db.GetContext(ctx, &identities, `SELECT COUNT(*) FROM auth_identities WHERE provider = 'clerk' AND subject = $1`, unknownSubject); err != nil {
		t.Fatal(err)
	}
	if users != 0 || identities != 0 {
		t.Fatalf("router wrote unknown Clerk subject: users=%d identities=%d", users, identities)
	}
}
