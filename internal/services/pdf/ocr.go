package pdf

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type OCRConfig struct {
	Enabled       bool
	Language      string
	CloudFallback string // "", "aws_textract"

	AWSRegion     string
	AWSAccessKey  string
	AWSSecretKey  string
	AWSSessionTok string
}

type OCRService struct {
	cfg        OCRConfig
	httpClient *http.Client
}

func NewOCRService(cfg OCRConfig) *OCRService {
	if cfg.Language == "" {
		cfg.Language = "eng"
	}
	return &OCRService{
		cfg: cfg,
		httpClient: &http.Client{
			Timeout: 90 * time.Second,
		},
	}
}

func (s *OCRService) IsConfigured() bool {
	return s != nil && s.cfg.Enabled
}

func (s *OCRService) Extract(ctx context.Context, data []byte) (*ExtractionResult, error) {
	if !s.IsConfigured() {
		return nil, fmt.Errorf("ocr service not enabled")
	}

	localResult, localErr := s.extractLocal(ctx, data)
	if localErr == nil && localResult.WordCount >= 20 {
		return localResult, nil
	}

	if s.cfg.CloudFallback == "aws_textract" && s.hasTextractCredentials() {
		cloudResult, cloudErr := s.extractWithTextract(ctx, data)
		if cloudErr == nil && cloudResult.WordCount > 0 {
			return cloudResult, nil
		}
		if localErr != nil {
			return nil, fmt.Errorf("local OCR failed (%v) and cloud OCR failed (%v)", localErr, cloudErr)
		}
	}

	if localErr != nil {
		return nil, localErr
	}
	return localResult, nil
}

func (s *OCRService) hasTextractCredentials() bool {
	return s.cfg.AWSRegion != "" && s.cfg.AWSAccessKey != "" && s.cfg.AWSSecretKey != ""
}

func (s *OCRService) extractLocal(ctx context.Context, data []byte) (*ExtractionResult, error) {
	pdfPath, cleanupPDF, err := writeTempPDF(data)
	if err != nil {
		return nil, err
	}
	defer cleanupPDF()

	images, cleanupImages, err := rasterizePDFPages(ctx, pdfPath, 250)
	if err != nil {
		return nil, err
	}
	defer cleanupImages()

	var allText strings.Builder
	textPages := 0
	for i, imagePath := range images {
		text, err := s.runTesseract(ctx, imagePath)
		if err != nil {
			return nil, err
		}
		text = strings.TrimSpace(text)
		if text != "" {
			textPages++
		}
		if i > 0 {
			allText.WriteString(fmt.Sprintf("\n--- Page %d ---\n", i+1))
		}
		allText.WriteString(text)
	}

	extracted := normalizeExtractedText(strings.TrimSpace(allText.String()))
	return &ExtractionResult{
		Text:             extracted,
		PageCount:        len(images),
		WordCount:        countWords(extracted),
		TextPages:        textPages,
		OCRRecommended:   false,
		ExtractionMethod: "ocr_local",
		OCRProvider:      "tesseract",
		OCRConfidence:    0,
	}, nil
}

func (s *OCRService) runTesseract(ctx context.Context, imagePath string) (string, error) {
	cmd := exec.CommandContext(ctx,
		"tesseract",
		imagePath,
		"stdout",
		"-l", s.cfg.Language,
		"--psm", "3",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("tesseract failed: %v (%s)", err, string(out))
	}
	return string(out), nil
}

func (s *OCRService) extractWithTextract(ctx context.Context, data []byte) (*ExtractionResult, error) {
	pdfPath, cleanupPDF, err := writeTempPDF(data)
	if err != nil {
		return nil, err
	}
	defer cleanupPDF()

	images, cleanupImages, err := rasterizePDFPages(ctx, pdfPath, 200)
	if err != nil {
		return nil, err
	}
	defer cleanupImages()

	var allText strings.Builder
	textPages := 0
	var confidenceSum float64
	var confidenceCount int

	for i, imagePath := range images {
		imageBytes, err := os.ReadFile(imagePath)
		if err != nil {
			return nil, fmt.Errorf("failed to read rasterized page: %w", err)
		}
		pageText, avgConfidence, err := s.textractDetectPage(ctx, imageBytes)
		if err != nil {
			return nil, err
		}
		pageText = strings.TrimSpace(pageText)
		if pageText != "" {
			textPages++
		}
		if i > 0 {
			allText.WriteString(fmt.Sprintf("\n--- Page %d ---\n", i+1))
		}
		allText.WriteString(pageText)
		if avgConfidence > 0 {
			confidenceSum += avgConfidence
			confidenceCount++
		}
	}

	extracted := normalizeExtractedText(strings.TrimSpace(allText.String()))
	confidence := 0.0
	if confidenceCount > 0 {
		confidence = confidenceSum / float64(confidenceCount)
	}

	return &ExtractionResult{
		Text:             extracted,
		PageCount:        len(images),
		WordCount:        countWords(extracted),
		TextPages:        textPages,
		OCRRecommended:   false,
		ExtractionMethod: "ocr_cloud",
		OCRProvider:      "aws_textract",
		OCRConfidence:    confidence,
	}, nil
}

type textractDetectRequest struct {
	Document struct {
		Bytes string `json:"Bytes"`
	} `json:"Document"`
}

type textractDetectResponse struct {
	Blocks []struct {
		BlockType  string  `json:"BlockType"`
		Text       string  `json:"Text"`
		Confidence float64 `json:"Confidence"`
	} `json:"Blocks"`
}

func (s *OCRService) textractDetectPage(ctx context.Context, imageBytes []byte) (string, float64, error) {
	var payload textractDetectRequest
	payload.Document.Bytes = base64.StdEncoding.EncodeToString(imageBytes)
	body, err := json.Marshal(payload)
	if err != nil {
		return "", 0, err
	}

	endpointHost := fmt.Sprintf("textract.%s.amazonaws.com", s.cfg.AWSRegion)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+endpointHost+"/", strings.NewReader(string(body)))
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Content-Type", "application/x-amz-json-1.1")
	req.Header.Set("X-Amz-Target", "Textract.DetectDocumentText")
	if s.cfg.AWSSessionTok != "" {
		req.Header.Set("X-Amz-Security-Token", s.cfg.AWSSessionTok)
	}

	if err := s.signTextractRequest(req, body); err != nil {
		return "", 0, err
	}

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", 0, fmt.Errorf("textract detect failed: status %d body=%s", resp.StatusCode, string(respBody))
	}

	var parsed textractDetectResponse
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return "", 0, fmt.Errorf("failed to parse textract response: %w", err)
	}

	lines := make([]string, 0, len(parsed.Blocks))
	confidenceSum := 0.0
	confidenceCount := 0
	for _, block := range parsed.Blocks {
		if block.BlockType != "LINE" || strings.TrimSpace(block.Text) == "" {
			continue
		}
		lines = append(lines, strings.TrimSpace(block.Text))
		if block.Confidence > 0 {
			confidenceSum += block.Confidence
			confidenceCount++
		}
	}
	avgConfidence := 0.0
	if confidenceCount > 0 {
		avgConfidence = confidenceSum / float64(confidenceCount)
	}
	return strings.Join(lines, "\n"), avgConfidence, nil
}

func (s *OCRService) signTextractRequest(req *http.Request, body []byte) error {
	now := time.Now().UTC()
	amzDate := now.Format("20060102T150405Z")
	shortDate := now.Format("20060102")
	service := "textract"
	scope := fmt.Sprintf("%s/%s/%s/aws4_request", shortDate, s.cfg.AWSRegion, service)

	host := req.URL.Host
	payloadHash := sha256HexBytes(body)

	req.Header.Set("Host", host)
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", payloadHash)

	canonicalHeaders := "content-type:" + req.Header.Get("Content-Type") + "\n" +
		"host:" + host + "\n" +
		"x-amz-content-sha256:" + payloadHash + "\n" +
		"x-amz-date:" + amzDate + "\n" +
		"x-amz-target:" + req.Header.Get("X-Amz-Target") + "\n"
	signedHeaders := "content-type;host;x-amz-content-sha256;x-amz-date;x-amz-target"
	if s.cfg.AWSSessionTok != "" {
		canonicalHeaders += "x-amz-security-token:" + s.cfg.AWSSessionTok + "\n"
		signedHeaders += ";x-amz-security-token"
	}

	canonicalRequest := strings.Join([]string{
		req.Method,
		"/",
		"",
		canonicalHeaders,
		signedHeaders,
		payloadHash,
	}, "\n")

	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		sha256HexString(canonicalRequest),
	}, "\n")

	signature := hex.EncodeToString(signV4(s.cfg.AWSSecretKey, shortDate, s.cfg.AWSRegion, service, stringToSign))
	req.Header.Set("Authorization",
		fmt.Sprintf(
			"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
			s.cfg.AWSAccessKey, scope, signedHeaders, signature,
		),
	)
	return nil
}

func writeTempPDF(data []byte) (string, func(), error) {
	f, err := os.CreateTemp("", "pdf-ocr-*.pdf")
	if err != nil {
		return "", nil, fmt.Errorf("failed to create temp pdf: %w", err)
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		_ = os.Remove(f.Name())
		return "", nil, fmt.Errorf("failed to write temp pdf: %w", err)
	}
	_ = f.Close()
	return f.Name(), func() { _ = os.Remove(f.Name()) }, nil
}

func rasterizePDFPages(ctx context.Context, pdfPath string, dpi int) ([]string, func(), error) {
	basePrefix := strings.TrimSuffix(pdfPath, filepath.Ext(pdfPath)) + "-page"
	cmd := exec.CommandContext(ctx, "pdftoppm", "-r", fmt.Sprintf("%d", dpi), "-png", pdfPath, basePrefix)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, nil, fmt.Errorf("pdftoppm failed: %v (%s)", err, string(out))
	}

	matches, err := filepath.Glob(basePrefix + "-*.png")
	if err != nil {
		return nil, nil, fmt.Errorf("failed to list rasterized pages: %w", err)
	}
	sort.Strings(matches)
	if len(matches) == 0 {
		return nil, nil, fmt.Errorf("no pages rasterized from PDF")
	}
	cleanup := func() {
		for _, p := range matches {
			_ = os.Remove(p)
		}
	}
	return matches, cleanup, nil
}

func sha256HexString(v string) string {
	sum := sha256.Sum256([]byte(v))
	return hex.EncodeToString(sum[:])
}

func sha256HexBytes(v []byte) string {
	sum := sha256.Sum256(v)
	return hex.EncodeToString(sum[:])
}

func hmacSHA256(key []byte, value string) []byte {
	m := hmac.New(sha256.New, key)
	_, _ = m.Write([]byte(value))
	return m.Sum(nil)
}

func signV4(secret, date, region, service, stringToSign string) []byte {
	kDate := hmacSHA256([]byte("AWS4"+secret), date)
	kRegion := hmacSHA256(kDate, region)
	kService := hmacSHA256(kRegion, service)
	kSigning := hmacSHA256(kService, "aws4_request")
	return hmacSHA256(kSigning, stringToSign)
}
