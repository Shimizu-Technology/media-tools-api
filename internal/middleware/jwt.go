// jwt.go provides JWT authentication middleware (MTA-20).
// This works alongside the existing API key auth for backward compatibility.
package middleware

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const userContextKey = "user"
const firstPartySessionContextKey = "first_party_session_id"
const clerkSessionContextKey = "clerk_session_id"

// JWTClaims extends standard JWT claims with user info.
type JWTClaims struct {
	UserID string `json:"user_id"`
	Email  string `json:"email"`
	jwt.RegisteredClaims
}

// GenerateJWT creates a new JWT token for a user.
func GenerateJWT(user *models.User, secret string) (string, error) {
	claims := JWTClaims{
		UserID: user.ID,
		Email:  user.Email,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(72 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			Subject:   user.ID,
		},
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(secret))
}

// ParseJWT validates and parses a JWT token string.
func ParseJWT(tokenString, secret string) (*JWTClaims, error) {
	token, err := jwt.ParseWithClaims(tokenString, &JWTClaims{}, func(token *jwt.Token) (interface{}, error) {
		if token.Method != jwt.SigningMethodHS256 {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return []byte(secret), nil
	})
	if err != nil {
		return nil, err
	}

	if claims, ok := token.Claims.(*JWTClaims); ok && token.Valid {
		return claims, nil
	}
	return nil, jwt.ErrSignatureInvalid
}

// JWTAuth returns middleware that validates JWT Bearer tokens.
// It sets the user in the context if a valid token is provided.
func JWTAuth(db *database.DB, jwtSecret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		authHeader := c.GetHeader("Authorization")
		if authHeader == "" || !strings.HasPrefix(authHeader, "Bearer ") {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "Missing or invalid Authorization header. Use 'Bearer <token>'",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		tokenString := strings.TrimPrefix(authHeader, "Bearer ")
		claims, err := ParseJWT(tokenString, jwtSecret)
		if err != nil {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "Invalid or expired token",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		// Look up the user
		user, err := db.GetUserByID(c.Request.Context(), claims.UserID)
		if err != nil {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "User not found",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		c.Set(userContextKey, user)
		c.Next()
	}
}

// DualAuth returns middleware that accepts an API key and the explicitly
// enabled bearer-token providers.
// Priority: 1) API key, 2) first-party session, 3) Clerk JWT, 4) legacy JWT.
// This ensures backward compatibility while enabling Clerk authentication.
func DualAuth(db *database.DB, jwtSecret string, jwksCache *JWKSCache, clerkSecretKey string, firstPartyEnabled, legacyAuthEnabled, clerkMigrationOnly bool) gin.HandlerFunc {
	acceptFirstParty := firstPartyEnabled
	return func(c *gin.Context) {
		// Try API key first
		rawKey := c.GetHeader("X-API-Key")
		if rawKey != "" {
			keyHash := HashAPIKey(rawKey)
			apiKey, err := db.GetAPIKeyByHash(c.Request.Context(), keyHash)
			if err == nil {
				c.Set(string(apiKeyContextKey), apiKey)
				// BUG FIX: Use context.Background() — goroutine outlives request
				go func() {
					ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					defer cancel()
					db.UpdateAPIKeyLastUsed(ctx, apiKey.ID)
				}()
				c.Next()
				return
			}
		}

		// Try Bearer token (Clerk or legacy JWT)
		authHeader := c.GetHeader("Authorization")
		if authHeader != "" && strings.HasPrefix(authHeader, "Bearer ") {
			tokenString := strings.TrimPrefix(authHeader, "Bearer ")
			if acceptFirstParty && strings.HasPrefix(tokenString, "mta_at_") {
				user, sessionID, err := db.GetUserByFirstPartyAccessToken(c.Request.Context(), tokenString)
				if err == nil {
					c.Set(userContextKey, user)
					c.Set(firstPartySessionContextKey, sessionID)
					c.Next()
					return
				}
				if err != database.ErrSessionInvalid {
					log.Printf("First-party credential lookup failed: %v", err)
					c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not verify session", Code: http.StatusServiceUnavailable})
					c.Abort()
					return
				}
				c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "Invalid or expired session", Code: http.StatusUnauthorized})
				c.Abort()
				return
			}

			// Try Clerk JWT first (RS256 via JWKS) if configured
			if jwksCache != nil {
				claims, err := jwksCache.ParseToken(tokenString)
				if err == nil {
					if claims.Subject != "" {
						if rejectAccountDeletionTombstone(c, db, claims.Subject) {
							return
						}
						var user *models.User
						if clerkMigrationOnly {
							user, err = db.ResolveMigrationClerkUser(c.Request.Context(), claims.Subject)
							if errors.Is(err, database.ErrClerkIdentityUnknown) {
								c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "Failed to verify user identity", Code: http.StatusUnauthorized})
								c.Abort()
								return
							}
						} else {
							user, err = db.GetUserByClerkID(c.Request.Context(), claims.Subject)
						}
						if err != nil && !clerkMigrationOnly {
							// Find or create via email migration flow
							clerkUser, fetchErr := fetchClerkUser(claims.Subject, clerkSecretKey)
							if fetchErr != nil {
								log.Printf("❌ DualAuth: failed to fetch Clerk user %s: %v", claims.Subject, fetchErr)
								c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
									Error:   "auth_provider_unavailable",
									Message: "Failed to verify user identity",
									Code:    http.StatusServiceUnavailable,
								})
								c.Abort()
								return
							} else {
								user, err = db.FindOrCreateClerkUser(c.Request.Context(), claims.Subject, clerkUser.Email, clerkUser.Name)
								if err != nil {
									if errors.Is(err, database.ErrClerkEmailConflict) {
										c.JSON(http.StatusConflict, models.ErrorResponse{
											Error:   "identity_conflict",
											Message: "An account with this email already exists. Sign in with its original method.",
											Code:    http.StatusConflict,
										})
										c.Abort()
										return
									}
									log.Printf("❌ DualAuth: failed to find/create Clerk user %s: %v", claims.Subject, err)
									// Clerk token is valid but DB failed — return 500, don't fall through to legacy JWT
									c.JSON(http.StatusInternalServerError, models.ErrorResponse{
										Error:   "server_error",
										Message: "Failed to authenticate user",
										Code:    http.StatusInternalServerError,
									})
									c.Abort()
									return
								}
							}
						}
						if err != nil {
							log.Printf("❌ DualAuth: failed to resolve Clerk user %s: %v", claims.Subject, err)
							c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Failed to authenticate user", Code: http.StatusServiceUnavailable})
							c.Abort()
							return
						}
						if user != nil {
							c.Set(userContextKey, user)
							if claims.SessionID != "" {
								c.Set(clerkSessionContextKey, claims.SessionID)
							}
							c.Next()
							return
						}
					}
				}
			}

			// A production first-party rollout must not keep accepting the old
			// shared-secret token format merely because JWT_SECRET is configured.
			// LEGACY_AUTH_ENABLED controls both issuance routes and acceptance.
			if legacyAuthEnabled {
				claims, err := ParseJWT(tokenString, jwtSecret)
				if err == nil {
					user, err := db.GetUserByID(c.Request.Context(), claims.UserID)
					if err == nil {
						c.Set(userContextKey, user)
						c.Next()
						return
					}
				}
			}
		}

		// Neither auth method worked
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Provide a valid X-API-Key header or Authorization: Bearer <token>",
			Code:    http.StatusUnauthorized,
		})
		c.Abort()
	}
}

func rejectAccountDeletionTombstone(c *gin.Context, db *database.DB, clerkUserID string) bool {
	blocked, err := db.HasAccountDeletionTombstone(c.Request.Context(), clerkUserID)
	if err != nil {
		log.Printf("❌ Failed to check account deletion tombstone for %s: %v", clerkUserID, err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "authentication_unavailable",
			Message: "Failed to verify account status",
			Code:    http.StatusServiceUnavailable,
		})
		c.Abort()
		return true
	}
	if !blocked {
		return false
	}
	c.JSON(http.StatusGone, models.ErrorResponse{
		Error:   "account_deletion_pending",
		Message: "This account has been deleted or is being deleted.",
		Code:    http.StatusGone,
	})
	c.Abort()
	return true
}

// GetUser retrieves the authenticated user from the request context.
func GetUser(c *gin.Context) *models.User {
	val, exists := c.Get(userContextKey)
	if !exists {
		return nil
	}
	user, ok := val.(*models.User)
	if !ok {
		return nil
	}
	return user
}

// AuthSessionBinding identifies the verified device or Clerk session that
// started a sensitive ceremony. Legacy JWTs and API keys have no binding and
// cannot enroll passkeys.
func AuthSessionBinding(c *gin.Context) string {
	if id, ok := c.Get(firstPartySessionContextKey); ok {
		if sessionID, ok := id.(string); ok && sessionID != "" {
			return "first-party:" + sessionID
		}
	}
	if id, ok := c.Get(clerkSessionContextKey); ok {
		if sessionID, ok := id.(string); ok && sessionID != "" {
			return "clerk:" + sessionID
		}
	}
	return ""
}

// BearerOnlyAuth accepts the enabled bearer-token providers but not API keys.
// Used for user-scoped routes like /auth/me and /workspace where an API key
// should not grant access.
func BearerOnlyAuth(db *database.DB, jwtSecret string, jwksCache *JWKSCache, clerkSecretKey string, firstPartyEnabled, legacyAuthEnabled, clerkMigrationOnly bool) gin.HandlerFunc {
	// Create DualAuth handler once at init, not per-request
	dualAuth := DualAuth(db, jwtSecret, jwksCache, clerkSecretKey, firstPartyEnabled, legacyAuthEnabled, clerkMigrationOnly)

	return func(c *gin.Context) {
		// Reject any request with API key, even if Authorization is also present
		if c.GetHeader("X-API-Key") != "" {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "This endpoint requires a Bearer token, not an API key",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		// Delegate to DualAuth for the enabled Bearer token providers.
		dualAuth(c)
	}
}
