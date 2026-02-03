// auth.go handles user authentication HTTP endpoints (MTA-20).
package handlers

import (
	"log"
	"net/http"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// Register creates a new user account.
// POST /api/v1/auth/register
func (h *Handler) Register(c *gin.Context) {
	var req models.RegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "Email, password (min 8 chars), and name are required",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Check if user already exists
	existing, _ := h.DB.GetUserByEmail(c.Request.Context(), req.Email)
	if existing != nil {
		c.JSON(http.StatusConflict, models.ErrorResponse{
			Error:   "email_taken",
			Message: "An account with this email already exists",
			Code:    http.StatusConflict,
		})
		return
	}

	// Hash password
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		log.Printf("❌ Failed to hash password: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "server_error",
			Message: "Failed to create account",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	user := &models.User{
		Email:        req.Email,
		PasswordHash: string(hash),
		Name:         req.Name,
	}

	if err := h.DB.CreateUser(c.Request.Context(), user); err != nil {
		log.Printf("❌ Failed to create user: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to create account",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Generate JWT
	token, err := middleware.GenerateJWT(user, h.JWTSecret)
	if err != nil {
		log.Printf("❌ Failed to generate token: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "token_error",
			Message: "Account created but failed to generate token",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusCreated, models.AuthResponse{
		Token: token,
		User:  *user,
	})
}

// Login authenticates a user and returns a JWT token.
// POST /api/v1/auth/login
func (h *Handler) Login(c *gin.Context) {
	var req models.LoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "Email and password are required",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Look up user
	user, err := h.DB.GetUserByEmail(c.Request.Context(), req.Email)
	if err != nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "invalid_credentials",
			Message: "Invalid email or password",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	// Verify password
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "invalid_credentials",
			Message: "Invalid email or password",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	// Generate JWT
	token, err := middleware.GenerateJWT(user, h.JWTSecret)
	if err != nil {
		log.Printf("❌ Failed to generate token: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "token_error",
			Message: "Failed to generate token",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusOK, models.AuthResponse{
		Token: token,
		User:  *user,
	})
}

// GetMe returns the current authenticated user.
// GET /api/v1/auth/me
func (h *Handler) GetMe(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Not authenticated",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	c.JSON(http.StatusOK, user)
}

// RefreshToken issues a new JWT token for an authenticated user.
// POST /api/v1/auth/refresh
//
// This endpoint allows clients to obtain a fresh token before the current
// one expires. Call this periodically (e.g., every hour) to maintain
// the session without requiring re-login.
func (h *Handler) RefreshToken(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Not authenticated",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	// Generate a fresh JWT
	token, err := middleware.GenerateJWT(user, h.JWTSecret)
	if err != nil {
		log.Printf("❌ Failed to refresh token: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "token_error",
			Message: "Failed to refresh token",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusOK, models.AuthResponse{
		Token: token,
		User:  *user,
	})
}
