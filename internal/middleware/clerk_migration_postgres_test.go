package middleware

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
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

type clerkJWTFixture struct {
	cache  *JWKSCache
	key    *rsa.PrivateKey
	issuer string
	server *httptest.Server
	keyID  string
}

func newClerkJWTFixture(t *testing.T) *clerkJWTFixture {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	keyID := "migration-test-key"
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		exponent := big.NewInt(int64(key.PublicKey.E)).Bytes()
		_ = json.NewEncoder(w).Encode(JWKSet{Keys: []JWK{{
			Kid: keyID,
			Kty: "RSA",
			Alg: "RS256",
			Use: "sig",
			N:   base64.RawURLEncoding.EncodeToString(key.PublicKey.N.Bytes()),
			E:   base64.RawURLEncoding.EncodeToString(exponent),
		}}})
	}))
	t.Cleanup(server.Close)
	return &clerkJWTFixture{
		cache:  NewJWKSCache(server.URL+"/.well-known/jwks.json", server.URL, "", ""),
		key:    key,
		issuer: server.URL,
		server: server,
		keyID:  keyID,
	}
}

func (f *clerkJWTFixture) token(t *testing.T, subject string) string {
	t.Helper()
	now := time.Now()
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, ClerkClaims{RegisteredClaims: jwt.RegisteredClaims{
		Issuer:    f.issuer,
		Subject:   subject,
		IssuedAt:  jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(now.Add(time.Hour)),
	}})
	token.Header["kid"] = f.keyID
	signed, err := token.SignedString(f.key)
	if err != nil {
		t.Fatal(err)
	}
	return signed
}

func openMiddlewarePostgres(t *testing.T) *database.DB {
	t.Helper()
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
	return db
}

func runClerkMiddleware(t *testing.T, middleware gin.HandlerFunc, token string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	engine.GET("/protected", middleware, func(c *gin.Context) {
		user := GetUser(c)
		if user == nil {
			c.Status(http.StatusInternalServerError)
			return
		}
		c.JSON(http.StatusOK, gin.H{"user_id": user.ID})
	})
	request := httptest.NewRequest(http.MethodGet, "/protected", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	engine.ServeHTTP(response, request)
	return response
}

func TestClerkMigrationOnlyMiddlewareAcceptsLinkedAndRejectsUnknown(t *testing.T) {
	db := openMiddlewarePostgres(t)
	ctx := context.Background()
	fixture := newClerkJWTFixture(t)
	linkedSubject := "user_" + uuid.NewString()
	unknownSubject := "user_" + uuid.NewString()
	var linkedID, sameEmailID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', 'Linked') RETURNING id`, uuid.NewString()+"@example.com").Scan(&linkedID); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', 'Same Email') RETURNING id`, "same-"+uuid.NewString()+"@example.com").Scan(&sameEmailID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id IN ($1, $2)`, linkedID, sameEmailID)
	})
	if err := db.EnsureAuthIdentity(ctx, linkedID, "clerk", linkedSubject); err != nil {
		t.Fatal(err)
	}

	linkedToken := fixture.token(t, linkedSubject)
	unknownToken := fixture.token(t, unknownSubject)
	for name, auth := range map[string]gin.HandlerFunc{
		"ClerkAuth": ClerkAuth(db, fixture.cache, "", true),
		"DualAuth":  DualAuth(db, "test-jwt-secret", fixture.cache, "", false, false, true),
	} {
		t.Run(name+" linked", func(t *testing.T) {
			response := runClerkMiddleware(t, auth, linkedToken)
			if response.Code != http.StatusOK {
				t.Fatalf("status = %d: %s", response.Code, response.Body.String())
			}
			var body struct {
				UserID string `json:"user_id"`
			}
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil || body.UserID != linkedID {
				t.Fatalf("body = %#v, %v", body, err)
			}
		})
		t.Run(name+" unknown", func(t *testing.T) {
			response := runClerkMiddleware(t, auth, unknownToken)
			if response.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d: %s", response.Code, response.Body.String())
			}
			var body models.ErrorResponse
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil || body.Error != "unauthorized" || body.Message != "Failed to verify user identity" {
				t.Fatalf("body = %#v, %v", body, err)
			}
		})
	}

	var unknownUsers, unknownIdentities int
	if err := db.GetContext(ctx, &unknownUsers, `SELECT COUNT(*) FROM users WHERE clerk_id = $1`, unknownSubject); err != nil {
		t.Fatal(err)
	}
	if err := db.GetContext(ctx, &unknownIdentities, `SELECT COUNT(*) FROM auth_identities WHERE provider = 'clerk' AND subject = $1`, unknownSubject); err != nil {
		t.Fatal(err)
	}
	if unknownUsers != 0 || unknownIdentities != 0 {
		t.Fatalf("unknown middleware subject wrote users=%d identities=%d", unknownUsers, unknownIdentities)
	}
}
