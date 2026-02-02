// Package pdf provides PDF text extraction (MTA-17).
//
// We use the ledongthuc/pdf library for text extraction.
// It's a pure Go implementation — no CGO or external dependencies required.
// This makes deployment simpler (just a single binary).
package pdf

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/ledongthuc/pdf"
)

// ExtractionResult holds the output from a PDF text extraction.
type ExtractionResult struct {
	Text      string // Extracted text content
	PageCount int    // Number of pages
	WordCount int    // Word count
}

// Extract reads a PDF from the given reader and extracts all text content.
//
// Go Pattern: We accept io.ReaderAt + size instead of a filename because
// the data comes from an HTTP upload (in memory), not a file on disk.
// The pdf library requires ReaderAt for random access to the PDF structure.
func Extract(data []byte) (*ExtractionResult, error) {
	reader := bytes.NewReader(data)
	size := int64(len(data))

	// Open the PDF reader
	pdfReader, err := pdf.NewReader(reader, size)
	if err != nil {
		return nil, fmt.Errorf("failed to open PDF: %w", err)
	}

	pageCount := pdfReader.NumPage()
	if pageCount == 0 {
		return &ExtractionResult{
			Text:      "",
			PageCount: 0,
			WordCount: 0,
		}, nil
	}

	// Extract text from each page
	var allText strings.Builder
	for i := 1; i <= pageCount; i++ {
		page := pdfReader.Page(i)
		if page.V.IsNull() {
			continue
		}

		text, err := page.GetPlainText(nil)
		if err != nil {
			// Log but don't fail — some pages may have images only
			allText.WriteString(fmt.Sprintf("\n--- Page %d (text extraction failed) ---\n", i))
			continue
		}

		if i > 1 {
			allText.WriteString(fmt.Sprintf("\n--- Page %d ---\n", i))
		}
		allText.WriteString(strings.TrimSpace(text))
	}

	extractedText := strings.TrimSpace(allText.String())
	wordCount := countWords(extractedText)

	return &ExtractionResult{
		Text:      extractedText,
		PageCount: pageCount,
		WordCount: wordCount,
	}, nil
}

// countWords counts the number of words in a text string.
func countWords(text string) int {
	words := strings.Fields(text)
	return len(words)
}

// ValidatePDF checks if the data looks like a valid PDF by checking the magic bytes.
func ValidatePDF(data []byte) bool {
	// PDF files start with "%PDF-"
	return len(data) >= 5 && string(data[:5]) == "%PDF-"
}
