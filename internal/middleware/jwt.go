// jwt.go provides JWT authentication middleware (MTA-20).
// This works alongside the existing API key auth for backward compatibility.
package middleware

import (
	"context"
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

// DualAuth returns middleware that accepts API key, Clerk JWT, OR legacy JWT.
// Priority: 1) API key, 2) Clerk JWT (RS256 via JWKS), 3) Legacy JWT (HS256).
// This ensures backward compatibility while enabling Clerk authentication.
func DualAuth(db *database.DB, jwtSecret string, jwksCache *JWKSCache, clerkSecretKey string) gin.HandlerFunc {
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

			// Try Clerk JWT first (RS256 via JWKS) if configured
			if jwksCache != nil {
				token, err := jwt.ParseWithClaims(tokenString, &ClerkClaims{}, func(token *jwt.Token) (interface{}, error) {
					if _, ok := token.Method.(*jwt.SigningMethodRSA); !ok {
						return nil, fmt.Errorf("not RSA")
					}
					kid, ok := token.Header["kid"].(string)
					if !ok {
						return nil, fmt.Errorf("missing kid")
					}
					return jwksCache.GetKey(kid)
				})
				if err == nil && token.Valid {
					if claims, ok := token.Claims.(*ClerkClaims); ok && claims.Subject != "" {
						user, err := db.GetUserByClerkID(c.Request.Context(), claims.Subject)
						if err != nil {
							// Find or create via email migration flow
							clerkUser, fetchErr := fetchClerkUser(claims.Subject, clerkSecretKey)
							if fetchErr == nil {
								var createErr error
								user, createErr = db.FindOrCreateClerkUser(c.Request.Context(), claims.Subject, clerkUser.Email, clerkUser.Name)
								if createErr != nil {
									log.Printf("❌ DualAuth: failed to find/create Clerk user %s: %v", claims.Subject, createErr)
								}
							}
						}
						if user != nil {
							c.Set(userContextKey, user)
							c.Next()
							return
						}
					}
				}
			}

			// Fall back to legacy JWT (HS256)
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

		// Neither auth method worked
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Provide a valid X-API-Key header or Authorization: Bearer <token>",
			Code:    http.StatusUnauthorized,
		})
		c.Abort()
	}
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
