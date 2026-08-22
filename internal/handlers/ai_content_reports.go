package handlers

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

var validAIContentReportTargets = map[string]bool{
	"chat_message":       true,
	"transcript_summary": true,
	"audio_summary":      true,
}

var validAIContentReportCategories = map[string]bool{
	"dangerous":          true,
	"hate_or_harassment": true,
	"sexual":             true,
	"privacy":            true,
	"deceptive":          true,
	"other":              true,
}

var validAIContentReportStatuses = map[string]bool{
	"reviewing": true,
	"resolved":  true,
	"dismissed": true,
}

// CreateAIContentReport accepts an in-app report for an AI response owned by
// the current actor. The server selects the output snapshot so a client cannot
// submit arbitrary or another account's content.
func (h *Handler) CreateAIContentReport(c *gin.Context) {
	var req models.CreateAIContentReportRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: "target_type, target_id, and category are required", Code: http.StatusBadRequest,
		})
		return
	}
	req.TargetType = strings.TrimSpace(req.TargetType)
	req.TargetID = strings.TrimSpace(req.TargetID)
	req.Category = strings.TrimSpace(req.Category)
	req.Details = strings.TrimSpace(req.Details)
	if err := validateAIContentReport(req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: err.Error(), Code: http.StatusBadRequest,
		})
		return
	}

	actor := getActorOwnership(c)
	report := &models.AIContentReport{
		TargetType: req.TargetType,
		TargetID:   req.TargetID,
		UserID:     actor.UserID,
		APIKeyID:   actor.APIKeyID,
		Category:   req.Category,
		Details:    req.Details,
	}
	created, err := h.DB.CreateAIContentReport(c.Request.Context(), report)
	if errors.Is(err, sql.ErrNoRows) {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "Reportable AI output not found", Code: http.StatusNotFound,
		})
		return
	}
	if err != nil {
		log.Printf("Failed to save AI output report: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "database_error", Message: "Failed to save AI output report", Code: http.StatusInternalServerError,
		})
		return
	}

	status := http.StatusCreated
	if !created {
		status = http.StatusOK
	}
	c.JSON(status, gin.H{
		"id":               report.ID,
		"status":           report.Status,
		"already_reported": !created,
	})
}

// ListAIContentReports exposes the moderation queue only to the configured
// owner API key.
func (h *Handler) ListAIContentReports(c *gin.Context) {
	if !h.isOwnerRequest(c) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{
			Error: "forbidden", Message: "Owner key required for AI report review", Code: http.StatusForbidden,
		})
		return
	}
	reports, err := h.DB.ListAIContentReports(c.Request.Context(), 100)
	if err != nil {
		log.Printf("Failed to load AI output reports: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "database_error", Message: "Failed to load AI output reports", Code: http.StatusInternalServerError,
		})
		return
	}
	c.JSON(http.StatusOK, gin.H{"data": reports})
}

// UpdateAIContentReport records an owner review decision.
func (h *Handler) UpdateAIContentReport(c *gin.Context) {
	if !h.isOwnerRequest(c) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{
			Error: "forbidden", Message: "Owner key required for AI report review", Code: http.StatusForbidden,
		})
		return
	}
	if _, err := uuid.Parse(c.Param("id")); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: "report id must be a UUID", Code: http.StatusBadRequest,
		})
		return
	}
	var req models.UpdateAIContentReportRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: "status is required", Code: http.StatusBadRequest,
		})
		return
	}
	req.Status = strings.TrimSpace(req.Status)
	req.AdminNote = strings.TrimSpace(req.AdminNote)
	if !validAIContentReportStatuses[req.Status] {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: "status must be reviewing, resolved, or dismissed", Code: http.StatusBadRequest,
		})
		return
	}
	if utf8.RuneCountInString(req.AdminNote) > 1000 {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: "admin_note must be 1000 characters or fewer", Code: http.StatusBadRequest,
		})
		return
	}
	report, err := h.DB.UpdateAIContentReport(c.Request.Context(), c.Param("id"), req.Status, req.AdminNote)
	if errors.Is(err, sql.ErrNoRows) {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "AI output report not found", Code: http.StatusNotFound,
		})
		return
	}
	if err != nil {
		log.Printf("Failed to update AI output report %s: %v", c.Param("id"), err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "database_error", Message: "Failed to update AI output report", Code: http.StatusInternalServerError,
		})
		return
	}
	c.JSON(http.StatusOK, report)
}

func validateAIContentReport(req models.CreateAIContentReportRequest) error {
	if !validAIContentReportTargets[req.TargetType] {
		return errors.New("target_type must be chat_message, transcript_summary, or audio_summary")
	}
	if _, err := uuid.Parse(req.TargetID); err != nil {
		return errors.New("target_id must be a UUID")
	}
	if !validAIContentReportCategories[req.Category] {
		return errors.New("category is not supported")
	}
	if utf8.RuneCountInString(req.Details) > 1000 {
		return errors.New("details must be 1000 characters or fewer")
	}
	return nil
}
