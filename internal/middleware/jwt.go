// jwt.go provides JWT authentication middleware (MTA-20).
// This works alongside the existing API key auth for backward compatibility.
package middleware

import (
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

// DualAuth returns middleware that accepts EITHER API key OR JWT token.
// This ensures backward compatibility: existing API key users keep working,
// while new JWT-authenticated users can also access protected routes.
func DualAuth(db *database.DB, jwtSecret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		// Try API key first
		rawKey := c.GetHeader("X-API-Key")
		if rawKey != "" {
			keyHash := HashAPIKey(rawKey)
			apiKey, err := db.GetAPIKeyByHash(c.Request.Context(), keyHash)
			if err == nil {
				c.Set(string(apiKeyContextKey), apiKey)
				go db.UpdateAPIKeyLastUsed(c.Request.Context(), apiKey.ID)
				c.Next()
				return
			}
		}

		// Try JWT token
		authHeader := c.GetHeader("Authorization")
		if authHeader != "" && strings.HasPrefix(authHeader, "Bearer ") {
			tokenString := strings.TrimPrefix(authHeader, "Bearer ")
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
