// pdf.go handles PDF text extraction HTTP endpoints (MTA-17).
//
// POST /api/v1/pdf/extract — Upload PDF file for text extraction
// GET  /api/v1/pdf/extractions/:id — Get extraction result by ID
// GET  /api/v1/pdf/extractions — List recent extractions
package handlers

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	pdfservice "github.com/Shimizu-Technology/media-tools-api/internal/services/pdf"
)

// maxPDFSize is the max upload size for PDF files (50MB).
const maxPDFSize = 50 << 20 // 50MB

// ExtractPDF handles PDF file upload and text extraction.
// POST /api/v1/pdf/extract
//
// Accepts multipart file upload with field name "file".
// Only .pdf files are accepted. Processing is synchronous.
func (h *Handler) ExtractPDF(c *gin.Context) {
	// Limit request body size
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxPDFSize)

	// Get the uploaded file
	file, header, err := c.Request.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "No PDF file provided. Upload a file with the field name 'file'. Max size: 50MB.",
			Code:    http.StatusBadRequest,
		})
		return
	}
	defer file.Close()

	// Validate file extension
	ext := strings.ToLower(filepath.Ext(header.Filename))
	if ext != ".pdf" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_file_type",
			Message: fmt.Sprintf("Unsupported file format '%s'. Only .pdf files are accepted.", ext),
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Read the entire file into memory for the PDF library
	// Go Pattern: io.ReadAll reads the entire reader into a byte slice.
	// For PDFs up to 50MB this is fine — the pdf library needs random access.
	data, err := io.ReadAll(file)
	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "read_error",
			Message: "Failed to read uploaded file",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Validate PDF magic bytes
	if !pdfservice.ValidatePDF(data) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_pdf",
			Message: "The uploaded file does not appear to be a valid PDF",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Generate a unique filename for storage reference
	storedFilename := uuid.New().String() + ".pdf"

	actor := getActorOwnership(c)

	// Extract text from the PDF (synchronous — PDFs process fast)
	result, err := pdfservice.Extract(data)
	if err != nil {
		log.Printf("PDF extraction failed for %s: %v", header.Filename, err)

		// Save the failed record
		pe := &models.PDFExtraction{
			Filename:     storedFilename,
			OriginalName: header.Filename,
			Status:       "failed",
			ErrorMessage: err.Error(),
			UserID:       actor.UserID,
			APIKeyID:     actor.APIKeyID,
		}
		if saveErr := h.DB.CreatePDFExtraction(c.Request.Context(), pe); saveErr != nil {
			log.Printf("Failed to save failed PDF extraction: %v", saveErr)
		} else {
			h.Worker.NotifyWebhook("pdf.failed", pe.UserID, pe.APIKeyID, pe)
		}

		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "extraction_failed",
			Message: "PDF text extraction failed: " + err.Error(),
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// If most pages have no extractable text layer, this is likely a scanned/image PDF.
	// Return a clear action message instead of a misleading mostly-empty extraction.
	if result.OCRRecommended {
		msg := fmt.Sprintf(
			"This PDF appears to be image/scanned-based (text found on %d of %d pages). OCR extraction is not enabled yet for scanned PDFs.",
			result.TextPages, result.PageCount,
		)
		log.Printf("PDF extraction requires OCR for %s: %s", header.Filename, msg)

		pe := &models.PDFExtraction{
			Filename:     storedFilename,
			OriginalName: header.Filename,
			PageCount:    result.PageCount,
			TextContent:  "",
			WordCount:    0,
			Status:       "failed",
			ErrorMessage: msg,
			UserID:       actor.UserID,
			APIKeyID:     actor.APIKeyID,
		}
		if saveErr := h.DB.CreatePDFExtraction(c.Request.Context(), pe); saveErr != nil {
			log.Printf("Failed to save OCR-required PDF extraction: %v", saveErr)
		} else {
			h.Worker.NotifyWebhook("pdf.failed", pe.UserID, pe.APIKeyID, pe)
		}

		c.JSON(http.StatusUnprocessableEntity, models.ErrorResponse{
			Error:   "ocr_required",
			Message: msg,
			Code:    http.StatusUnprocessableEntity,
		})
		return
	}

	// Save the successful extraction
	pe := &models.PDFExtraction{
		Filename:     storedFilename,
		OriginalName: header.Filename,
		PageCount:    result.PageCount,
		TextContent:  result.Text,
		WordCount:    result.WordCount,
		Status:       "completed",
		UserID:       actor.UserID,
		APIKeyID:     actor.APIKeyID,
	}

	if err := h.DB.CreatePDFExtraction(c.Request.Context(), pe); err != nil {
		log.Printf("Failed to save PDF extraction record: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "PDF text was extracted but could not be saved. Please try again.",
			Code:    http.StatusInternalServerError,
		})
		return
	}
	h.Worker.NotifyWebhook("pdf.completed", pe.UserID, pe.APIKeyID, pe)

	c.JSON(http.StatusOK, pe)
}

// GetPDFExtraction retrieves a single PDF extraction by ID.
// GET /api/v1/pdf/extractions/:id
func (h *Handler) GetPDFExtraction(c *gin.Context) {
	id := c.Param("id")
	actor := getActorOwnership(c)

	pe, err := h.DB.GetPDFExtractionForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "PDF extraction not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, pe)
}

// ListPDFExtractions returns recent PDF extractions for the authenticated API key.
// GET /api/v1/pdf/extractions
func (h *Handler) ListPDFExtractions(c *gin.Context) {
	actor := getActorOwnership(c)

	extractions, err := h.DB.ListPDFExtractions(c.Request.Context(), 50, actor.UserID, actor.APIKeyID)
	if err != nil {
		log.Printf("Failed to list PDF extractions: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to list PDF extractions",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	if extractions == nil {
		extractions = []models.PDFExtraction{}
	}

	c.JSON(http.StatusOK, extractions)
}

// DeletePDFExtraction removes a PDF extraction by ID.
// DELETE /api/v1/pdf/extractions/:id
func (h *Handler) DeletePDFExtraction(c *gin.Context) {
	id := c.Param("id")
	actor := getActorOwnership(c)

	if err := h.DB.DeletePDFExtractionForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID); err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "PDF extraction not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "PDF extraction deleted"})
}
