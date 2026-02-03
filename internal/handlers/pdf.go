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

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
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

	// Get the API key from context (set by auth middleware)
	var apiKeyID *string
	if apiKey := middleware.GetAPIKey(c); apiKey != nil {
		apiKeyID = &apiKey.ID
	}

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
			APIKeyID:     apiKeyID,
		}
		h.DB.CreatePDFExtraction(c.Request.Context(), pe)

		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "extraction_failed",
			Message: "PDF text extraction failed: " + err.Error(),
			Code:    http.StatusInternalServerError,
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
		APIKeyID:     apiKeyID,
	}

	if err := h.DB.CreatePDFExtraction(c.Request.Context(), pe); err != nil {
		log.Printf("Failed to save PDF extraction record: %v", err)
		// Still return the result even if DB save fails
	}

	c.JSON(http.StatusOK, pe)
}

// GetPDFExtraction retrieves a single PDF extraction by ID.
// GET /api/v1/pdf/extractions/:id
func (h *Handler) GetPDFExtraction(c *gin.Context) {
	id := c.Param("id")

	pe, err := h.DB.GetPDFExtraction(c.Request.Context(), id)
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
	// Get the API key from context to filter by owner
	var apiKeyID *string
	if apiKey := middleware.GetAPIKey(c); apiKey != nil {
		apiKeyID = &apiKey.ID
	}

	extractions, err := h.DB.ListPDFExtractions(c.Request.Context(), 50, apiKeyID)
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
