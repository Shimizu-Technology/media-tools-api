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
	Text           string // Extracted text content
	Pages          []PageContent
	PageCount      int  // Number of pages
	WordCount      int  // Word count
	TextPages      int  // Pages with extracted text
	OCRRecommended bool // True when doc looks image/scanned-heavy
}

// PageContent preserves document page boundaries for source citations.
type PageContent struct {
	PageNumber int
	Text       string
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
	pages := make([]PageContent, 0, pageCount)
	textPages := 0
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

		trimmed := normalizeExtractedText(strings.TrimSpace(text))
		if trimmed != "" {
			textPages++
			pages = append(pages, PageContent{PageNumber: i, Text: trimmed})
		}
		if allText.Len() > 0 {
			allText.WriteString(fmt.Sprintf("\n--- Page %d ---\n", i))
		}
		allText.WriteString(trimmed)
	}

	extractedText := strings.TrimSpace(allText.String())
	extractedText = normalizeExtractedText(extractedText)
	wordCount := countWords(extractedText)
	ocrRecommended := pageCount >= 3 && (textPages*100/pageCount) < 40

	return &ExtractionResult{
		Text:           extractedText,
		Pages:          pages,
		PageCount:      pageCount,
		WordCount:      wordCount,
		TextPages:      textPages,
		OCRRecommended: ocrRecommended,
	}, nil
}

// countWords counts the number of words in a text string.
func countWords(text string) int {
	words := strings.Fields(text)
	return len(words)
}

// normalizeExtractedText reflows overly-fragmented PDF text into readable paragraphs.
// Some PDFs extract as one word per line; this converts those blocks into normal text
// while preserving explicit page separators and simple list formatting.
func normalizeExtractedText(text string) string {
	if text == "" {
		return ""
	}
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	out := make([]string, 0, len(lines))
	block := make([]string, 0, 32)

	flushBlock := func() {
		if len(block) == 0 {
			return
		}
		shortLines := 0
		for _, line := range block {
			if wordCountInLine(line) <= 3 {
				shortLines++
			}
		}

		// If most lines are very short, the extractor likely wrapped each phrase/word.
		// Reflow the block into a single paragraph.
		if shortLines*100/len(block) >= 70 {
			out = append(out, joinBlockAsParagraph(block))
		} else {
			out = append(out, block...)
		}
		block = block[:0]
	}

	for _, raw := range lines {
		line := strings.TrimSpace(raw)

		if line == "" {
			flushBlock()
			if len(out) == 0 || out[len(out)-1] != "" {
				out = append(out, "")
			}
			continue
		}

		if isPageDivider(line) {
			flushBlock()
			if len(out) > 0 && out[len(out)-1] != "" {
				out = append(out, "")
			}
			out = append(out, line, "")
			continue
		}

		block = append(block, line)
	}
	flushBlock()

	// Collapse excessive blank lines.
	clean := make([]string, 0, len(out))
	prevBlank := false
	for _, line := range out {
		blank := strings.TrimSpace(line) == ""
		if blank && prevBlank {
			continue
		}
		clean = append(clean, line)
		prevBlank = blank
	}

	return strings.TrimSpace(strings.Join(clean, "\n"))
}

func isPageDivider(line string) bool {
	return strings.HasPrefix(line, "--- Page ") && strings.HasSuffix(line, " ---")
}

func wordCountInLine(line string) int {
	return len(strings.Fields(line))
}

func joinBlockAsParagraph(lines []string) string {
	var b strings.Builder
	for _, line := range lines {
		if line == "" {
			continue
		}
		if b.Len() == 0 {
			b.WriteString(line)
			continue
		}

		// Preserve simple list markers as new lines.
		if strings.HasPrefix(line, "- ") || strings.HasPrefix(line, "* ") || strings.HasPrefix(line, "• ") {
			b.WriteString("\n")
			b.WriteString(line)
			continue
		}

		current := b.String()
		if strings.HasSuffix(current, "-") {
			// Handle word breaks split with trailing hyphen.
			b.Reset()
			b.WriteString(strings.TrimSuffix(current, "-"))
			b.WriteString(line)
			continue
		}

		b.WriteString(" ")
		b.WriteString(line)
	}
	return strings.TrimSpace(b.String())
}

// ValidatePDF checks if the data looks like a valid PDF by checking the magic bytes.
func ValidatePDF(data []byte) bool {
	// PDF files start with "%PDF-"
	return len(data) >= 5 && string(data[:5]) == "%PDF-"
}
