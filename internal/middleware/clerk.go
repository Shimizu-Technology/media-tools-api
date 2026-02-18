// clerk.go provides Clerk JWT verification middleware.
//
// Clerk issues JWTs signed with RS256. We verify them using the JWKS endpoint
// (JSON Web Key Set) which publishes Clerk's public keys. Keys are cached
// and refreshed periodically for performance.
package middleware

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// JWKSCache caches Clerk's public keys to avoid fetching on every request.
type JWKSCache struct {
	mu       sync.RWMutex
	keys     map[string]*rsa.PublicKey
	url      string
	lastFetch time.Time
	ttl      time.Duration
}

// JWKSet represents the JWKS response format.
type JWKSet struct {
	Keys []JWK `json:"keys"`
}

// JWK represents a single JSON Web Key.
type JWK struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	Alg string `json:"alg"`
	Use string `json:"use"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// NewJWKSCache creates a new JWKS cache for the given URL.
func NewJWKSCache(jwksURL string) *JWKSCache {
	return &JWKSCache{
		url:  jwksURL,
		keys: make(map[string]*rsa.PublicKey),
		ttl:  1 * time.Hour,
	}
}

// GetKey returns the RSA public key for the given key ID, fetching from JWKS if needed.
func (c *JWKSCache) GetKey(kid string) (*rsa.PublicKey, error) {
	c.mu.RLock()
	if key, ok := c.keys[kid]; ok && time.Since(c.lastFetch) < c.ttl {
		c.mu.RUnlock()
		return key, nil
	}
	c.mu.RUnlock()

	// Fetch fresh keys
	if err := c.refresh(); err != nil {
		return nil, err
	}

	c.mu.RLock()
	defer c.mu.RUnlock()
	key, ok := c.keys[kid]
	if !ok {
		return nil, fmt.Errorf("key %s not found in JWKS", kid)
	}
	return key, nil
}

func (c *JWKSCache) refresh() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Double-check after acquiring write lock
	if time.Since(c.lastFetch) < 30*time.Second {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, "GET", c.url, nil)
	if err != nil {
		return fmt.Errorf("failed to create JWKS request: %w", err)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to fetch JWKS: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return fmt.Errorf("JWKS returned status %d", resp.StatusCode)
	}

	var jwks JWKSet
	if err := json.NewDecoder(resp.Body).Decode(&jwks); err != nil {
		return fmt.Errorf("failed to parse JWKS: %w", err)
	}

	newKeys := make(map[string]*rsa.PublicKey)
	for _, jwk := range jwks.Keys {
		if jwk.Kty != "RSA" {
			continue
		}
		key, err := jwkToRSAPublicKey(jwk)
		if err != nil {
			log.Printf("⚠️  Failed to parse JWK kid=%s: %v", jwk.Kid, err)
			continue
		}
		newKeys[jwk.Kid] = key
	}

	c.keys = newKeys
	c.lastFetch = time.Now()
	log.Printf("🔑 Refreshed JWKS cache: %d keys from %s", len(newKeys), c.url)
	return nil
}

// jwkToRSAPublicKey converts a JWK to an RSA public key.
func jwkToRSAPublicKey(jwk JWK) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(jwk.N)
	if err != nil {
		return nil, fmt.Errorf("failed to decode N: %w", err)
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(jwk.E)
	if err != nil {
		return nil, fmt.Errorf("failed to decode E: %w", err)
	}

	n := new(big.Int).SetBytes(nBytes)
	e := 0
	for _, b := range eBytes {
		e = e<<8 + int(b)
	}

	return &rsa.PublicKey{N: n, E: e}, nil
}

// ClerkClaims represents the JWT claims from a Clerk-issued token.
type ClerkClaims struct {
	jwt.RegisteredClaims
}

// ClerkAuth returns middleware that validates Clerk JWT Bearer tokens.
// It verifies the token using JWKS, looks up (or auto-creates) the user in the DB.
func ClerkAuth(db *database.DB, jwksCache *JWKSCache, clerkSecretKey string) gin.HandlerFunc {
	return func(c *gin.Context) {
		authHeader := c.GetHeader("Authorization")
		if authHeader == "" || !strings.HasPrefix(authHeader, "Bearer ") {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "Missing or invalid Authorization header",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		tokenString := strings.TrimPrefix(authHeader, "Bearer ")

		// Parse the token header to get the kid
		token, err := jwt.ParseWithClaims(tokenString, &ClerkClaims{}, func(token *jwt.Token) (interface{}, error) {
			// Ensure the signing method is RSA
			if _, ok := token.Method.(*jwt.SigningMethodRSA); !ok {
				return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
			}

			kid, ok := token.Header["kid"].(string)
			if !ok {
				return nil, fmt.Errorf("missing kid in token header")
			}

			return jwksCache.GetKey(kid)
		})

		if err != nil || !token.Valid {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "Invalid or expired Clerk token",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		claims, ok := token.Claims.(*ClerkClaims)
		if !ok {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "Failed to parse token claims",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		clerkUserID := claims.Subject
		if clerkUserID == "" {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "Missing user ID in token",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		// Find or create user via the invite-only / migration flow:
		// 1. Find by clerk_id (returning user)
		// 2. Find by email (legacy user migrating to Clerk → link clerk_id)
		// 3. Create new user
		clerkUser, fetchErr := fetchClerkUser(clerkUserID, clerkSecretKey)
		if fetchErr != nil {
			log.Printf("❌ Failed to fetch Clerk user %s: %v", clerkUserID, fetchErr)
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "Failed to verify user identity",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		user, err := db.FindOrCreateClerkUser(c.Request.Context(), clerkUserID, clerkUser.Email, clerkUser.Name)
		if err != nil {
			log.Printf("❌ Failed to find/create user for clerk_id %s: %v", clerkUserID, err)
			c.JSON(http.StatusInternalServerError, models.ErrorResponse{
				Error:   "server_error",
				Message: "Failed to authenticate user",
				Code:    http.StatusInternalServerError,
			})
			c.Abort()
			return
		}

		c.Set(userContextKey, user)
		c.Next()
	}
}

// clerkUserResponse is a subset of Clerk's user object.
type clerkUserResponse struct {
	ID             string `json:"id"`
	EmailAddresses []struct {
		EmailAddress string `json:"email_address"`
	} `json:"email_addresses"`
	FirstName string `json:"first_name"`
	LastName  string `json:"last_name"`
}

// fetchClerkUser retrieves user details from Clerk's Backend API.
func fetchClerkUser(clerkUserID, secretKey string) (*struct{ Email, Name string }, error) {
	if secretKey == "" {
		return nil, fmt.Errorf("CLERK_SECRET_KEY not configured")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	url := fmt.Sprintf("https://api.clerk.com/v1/users/%s", clerkUserID)
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+secretKey)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("Clerk API returned status %d", resp.StatusCode)
	}

	var clerkUser clerkUserResponse
	if err := json.NewDecoder(resp.Body).Decode(&clerkUser); err != nil {
		return nil, err
	}

	email := ""
	if len(clerkUser.EmailAddresses) > 0 {
		email = clerkUser.EmailAddresses[0].EmailAddress
	}

	name := strings.TrimSpace(clerkUser.FirstName + " " + clerkUser.LastName)

	return &struct{ Email, Name string }{Email: email, Name: name}, nil
}
