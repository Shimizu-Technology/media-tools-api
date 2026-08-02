// chat.go handles transcript chat endpoints (MTA-27).
package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	evidenceservice "github.com/Shimizu-Technology/media-tools-api/internal/services/evidence"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
)

type chatTarget struct {
	ItemType     string
	ItemID       string
	ContextLabel string
	Text         string
	Title        string
	UserID       *string
	APIKeyID     *string
}

func (h *Handler) loadTranscriptChatTarget(c *gin.Context) (*chatTarget, *models.ErrorResponse, int) {
	transcriptID := c.Param("id")
	actor := getActorOwnership(c)
	t, err := h.DB.GetTranscriptForActor(c.Request.Context(), transcriptID, actor.UserID, actor.APIKeyID)
	if err != nil {
		return nil, &models.ErrorResponse{
			Error:   "not_found",
			Message: "Transcript not found",
			Code:    http.StatusNotFound,
		}, http.StatusNotFound
	}
	if t.Status != models.StatusCompleted || t.TranscriptText == "" {
		return nil, &models.ErrorResponse{
			Error:   "transcript_not_ready",
			Message: "Transcript is not ready for chat",
			Code:    http.StatusConflict,
		}, http.StatusConflict
	}
	return &chatTarget{
		ItemType:     "transcript",
		ItemID:       t.ID,
		ContextLabel: "YouTube transcript",
		Text:         t.TranscriptText,
		Title:        t.Title,
		UserID:       actor.UserID,
		APIKeyID:     actor.APIKeyID,
	}, nil, 0
}

func (h *Handler) loadAudioChatTarget(c *gin.Context) (*chatTarget, *models.ErrorResponse, int) {
	audioID := c.Param("id")
	actor := getActorOwnership(c)
	at, err := h.DB.GetAudioTranscriptionForActor(c.Request.Context(), audioID, actor.UserID, actor.APIKeyID)
	if err != nil {
		return nil, &models.ErrorResponse{
			Error:   "not_found",
			Message: "Audio transcription not found",
			Code:    http.StatusNotFound,
		}, http.StatusNotFound
	}
	if at.Status != "completed" || at.TranscriptText == "" {
		return nil, &models.ErrorResponse{
			Error:   "transcription_not_ready",
			Message: "Audio transcription is not ready for chat",
			Code:    http.StatusConflict,
		}, http.StatusConflict
	}
	return &chatTarget{
		ItemType:     "audio",
		ItemID:       at.ID,
		ContextLabel: "audio transcription",
		Text:         at.TranscriptText,
		Title:        at.OriginalName,
		UserID:       actor.UserID,
		APIKeyID:     actor.APIKeyID,
	}, nil, 0
}

func (h *Handler) loadPDFChatTarget(c *gin.Context) (*chatTarget, *models.ErrorResponse, int) {
	pdfID := c.Param("id")
	actor := getActorOwnership(c)
	pe, err := h.DB.GetPDFExtractionForActor(c.Request.Context(), pdfID, actor.UserID, actor.APIKeyID)
	if err != nil {
		return nil, &models.ErrorResponse{
			Error:   "not_found",
			Message: "PDF extraction not found",
			Code:    http.StatusNotFound,
		}, http.StatusNotFound
	}
	if pe.Status != "completed" || pe.TextContent == "" {
		return nil, &models.ErrorResponse{
			Error:   "extraction_not_ready",
			Message: "PDF extraction is not ready for chat",
			Code:    http.StatusConflict,
		}, http.StatusConflict
	}
	return &chatTarget{
		ItemType:     "pdf",
		ItemID:       pe.ID,
		ContextLabel: "PDF text extraction",
		Text:         pe.TextContent,
		Title:        pe.OriginalName,
		UserID:       actor.UserID,
		APIKeyID:     actor.APIKeyID,
	}, nil, 0
}

func (h *Handler) getChatResponse(c *gin.Context, target *chatTarget) {
	session, err := h.DB.GetOrCreateChatSession(c.Request.Context(), target.ItemType, target.ItemID, target.UserID, target.APIKeyID)
	if err != nil {
		log.Printf("Chat session load failed (%s:%s): %v", target.ItemType, target.ItemID, err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to load chat session",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	messages, err := h.DB.ListChatMessages(c.Request.Context(), session.ID, 100)
	if err != nil {
		log.Printf("Chat messages load failed (session %s): %v", session.ID, err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to load chat messages",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	if messages == nil {
		messages = []models.TranscriptChatMessage{}
	}

	c.JSON(http.StatusOK, models.ChatResponse{
		Session:  *session,
		Messages: messages,
	})
}

func (h *Handler) postChatResponse(c *gin.Context, target *chatTarget, req models.CreateChatMessageRequest) {
	if h.Summarizer == nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "service_unavailable",
			Message: "AI chat is not configured. Set the OPENROUTER_API_KEY environment variable.",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}

	req.Message = strings.TrimSpace(req.Message)
	if req.Message == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "message cannot be empty",
			Code:    http.StatusBadRequest,
		})
		return
	}

	session, err := h.DB.GetOrCreateChatSession(c.Request.Context(), target.ItemType, target.ItemID, target.UserID, target.APIKeyID)
	if err != nil {
		log.Printf("Chat session load failed (%s:%s): %v", target.ItemType, target.ItemID, err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to load chat session",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	history, err := h.DB.ListChatMessages(c.Request.Context(), session.ID, 40)
	if err != nil {
		log.Printf("Chat history load failed (session %s): %v", session.ID, err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to load chat history",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	userMsg := &models.TranscriptChatMessage{
		SessionID: session.ID,
		Role:      "user",
		Content:   req.Message,
		ModelUsed: "",
	}
	if err := h.DB.CreateChatMessage(c.Request.Context(), userMsg); err != nil {
		log.Printf("Chat message save failed (session %s): %v", session.ID, err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to save message",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	chatHistory := make([]summary.ChatMessage, 0, len(history)+1)
	for _, m := range history {
		chatHistory = append(chatHistory, summary.ChatMessage{
			Role:    m.Role,
			Content: m.Content,
		})
	}
	chatHistory = append(chatHistory, summary.ChatMessage{
		Role:    "user",
		Content: req.Message,
	})

	segments, err := h.DB.SearchMediaSegments(
		c.Request.Context(),
		target.ItemType,
		target.ItemID,
		req.Message,
		15,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "database_error", Message: "Failed to retrieve source evidence", Code: http.StatusInternalServerError,
		})
		return
	}
	if len(segments) == 0 {
		legacy := evidenceservice.ChunkText(target.Text, 1_200)
		if len(legacy) > 0 {
			if err := h.DB.ReplaceMediaSegments(c.Request.Context(), target.ItemType, target.ItemID, legacy); err != nil {
				log.Printf("Legacy evidence backfill failed (%s:%s): %v", target.ItemType, target.ItemID, err)
			} else {
				segments, _ = h.DB.SearchMediaSegments(
					c.Request.Context(), target.ItemType, target.ItemID, req.Message, 15,
				)
			}
		}
	}
	if len(segments) == 0 {
		c.JSON(http.StatusConflict, models.ErrorResponse{
			Error: "no_evidence", Message: "No source evidence is available for chat", Code: http.StatusConflict,
		})
		return
	}

	answer, err := h.Summarizer.ChatEvidence(
		c.Request.Context(),
		target.ContextLabel,
		evidenceservice.ToSummarySegments(segments, target.Title),
		chatHistory,
		req.Model,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "ai_error",
			Message: summary.PublicChatErrorMessage(err),
			Code:    http.StatusInternalServerError,
		})
		return
	}

	assistantMsg := &models.TranscriptChatMessage{
		SessionID: session.ID,
		Role:      "assistant",
		Content:   strings.TrimSpace(answer.Answer),
		ModelUsed: answer.Model,
	}
	assistantMsg.Citations, _ = json.Marshal(answer.Citations)
	if err := h.DB.CreateChatMessage(c.Request.Context(), assistantMsg); err != nil {
		log.Printf("Assistant message save failed (session %s): %v", session.ID, err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to save assistant response",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusOK, models.ChatResponse{
		Session:  *session,
		Messages: []models.TranscriptChatMessage{*userMsg, *assistantMsg},
	})
}

// GetTranscriptChat returns the chat session and messages for a transcript.
// GET /api/v1/transcripts/:id/chat
func (h *Handler) GetTranscriptChat(c *gin.Context) {
	target, apiErr, status := h.loadTranscriptChatTarget(c)
	if apiErr != nil {
		c.JSON(status, *apiErr)
		return
	}
	h.getChatResponse(c, target)
}

// PostTranscriptChat sends a message and returns the AI response.
// POST /api/v1/transcripts/:id/chat
func (h *Handler) PostTranscriptChat(c *gin.Context) {
	var req models.CreateChatMessageRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "message is required",
			Code:    http.StatusBadRequest,
		})
		return
	}

	target, apiErr, status := h.loadTranscriptChatTarget(c)
	if apiErr != nil {
		c.JSON(status, *apiErr)
		return
	}
	h.postChatResponse(c, target, req)
}

// GetAudioChat returns the chat session and messages for an audio transcription.
// GET /api/v1/audio/transcriptions/:id/chat
func (h *Handler) GetAudioChat(c *gin.Context) {
	target, apiErr, status := h.loadAudioChatTarget(c)
	if apiErr != nil {
		c.JSON(status, *apiErr)
		return
	}
	h.getChatResponse(c, target)
}

// PostAudioChat sends a message and returns the AI response for audio.
// POST /api/v1/audio/transcriptions/:id/chat
func (h *Handler) PostAudioChat(c *gin.Context) {
	var req models.CreateChatMessageRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "message is required",
			Code:    http.StatusBadRequest,
		})
		return
	}
	target, apiErr, status := h.loadAudioChatTarget(c)
	if apiErr != nil {
		c.JSON(status, *apiErr)
		return
	}
	h.postChatResponse(c, target, req)
}

// GetPDFChat returns the chat session and messages for a PDF extraction.
// GET /api/v1/pdf/extractions/:id/chat
func (h *Handler) GetPDFChat(c *gin.Context) {
	target, apiErr, status := h.loadPDFChatTarget(c)
	if apiErr != nil {
		c.JSON(status, *apiErr)
		return
	}
	h.getChatResponse(c, target)
}

// PostPDFChat sends a message and returns the AI response for a PDF extraction.
// POST /api/v1/pdf/extractions/:id/chat
func (h *Handler) PostPDFChat(c *gin.Context) {
	var req models.CreateChatMessageRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "message is required",
			Code:    http.StatusBadRequest,
		})
		return
	}
	target, apiErr, status := h.loadPDFChatTarget(c)
	if apiErr != nil {
		c.JSON(status, *apiErr)
		return
	}
	h.postChatResponse(c, target, req)
}
