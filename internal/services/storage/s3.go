package storage

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	s3Service = "s3"
)

type S3 struct {
	accessKey  string
	secretKey  string
	sessionTok string
	region     string
	bucket     string
	prefix     string
	expiry     time.Duration
	client     *http.Client
}

func NewS3(accessKey, secretKey, sessionTok, region, bucket, prefix string, expiryMinutes int) *S3 {
	if expiryMinutes <= 0 {
		expiryMinutes = 60
	}
	return &S3{
		accessKey:  accessKey,
		secretKey:  secretKey,
		sessionTok: sessionTok,
		region:     region,
		bucket:     bucket,
		prefix:     strings.Trim(prefix, "/"),
		expiry:     time.Duration(expiryMinutes) * time.Minute,
		client:     &http.Client{Timeout: 2 * time.Minute},
	}
}

func (s *S3) IsConfigured() bool {
	return s != nil && s.accessKey != "" && s.secretKey != "" && s.region != "" && s.bucket != ""
}

func (s *S3) BuildKey(filename string) string {
	base := filepath.Base(filename)
	if s.prefix == "" {
		return base
	}
	return fmt.Sprintf("%s/%s", s.prefix, base)
}

func (s *S3) UploadFile(ctx context.Context, localPath, key, contentType string) error {
	f, err := os.Open(localPath)
	if err != nil {
		return fmt.Errorf("open file: %w", err)
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		return fmt.Errorf("stat file: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPut, s.objectURL(key), f)
	if err != nil {
		return fmt.Errorf("create upload request: %w", err)
	}
	req.ContentLength = stat.Size()
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if err := s.signRequest(req, key, "UNSIGNED-PAYLOAD"); err != nil {
		return err
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("upload request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("upload failed: status %d body=%s", resp.StatusCode, string(body))
	}
	return nil
}

func (s *S3) DownloadFile(ctx context.Context, key, localPath string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.objectURL(key), nil)
	if err != nil {
		return fmt.Errorf("create download request: %w", err)
	}
	if err := s.signRequest(req, key, "UNSIGNED-PAYLOAD"); err != nil {
		return err
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("download request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("download failed: status %d body=%s", resp.StatusCode, string(body))
	}

	out, err := os.Create(localPath)
	if err != nil {
		return fmt.Errorf("create output file: %w", err)
	}
	defer out.Close()
	if _, err := io.Copy(out, resp.Body); err != nil {
		return fmt.Errorf("save output file: %w", err)
	}
	return nil
}

func (s *S3) DeleteObject(ctx context.Context, key string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, s.objectURL(key), nil)
	if err != nil {
		return fmt.Errorf("create delete request: %w", err)
	}
	if err := s.signRequest(req, key, "UNSIGNED-PAYLOAD"); err != nil {
		return err
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("delete request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusNotFound {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("delete failed: status %d body=%s", resp.StatusCode, string(body))
	}
	return nil
}

func (s *S3) PresignedGetURL(key string) (string, error) {
	if key == "" {
		return "", fmt.Errorf("empty key")
	}
	now := time.Now().UTC()
	expires := int(s.expiry.Seconds())
	if expires < 60 {
		expires = 60
	}
	if expires > 604800 {
		expires = 604800
	}

	escapedKey := escapeS3KeyPath(key)
	host := s.host()
	path := "/" + escapedKey
	amzDate := now.Format("20060102T150405Z")
	shortDate := now.Format("20060102")
	scope := fmt.Sprintf("%s/%s/%s/aws4_request", shortDate, s.region, s3Service)

	query := url.Values{}
	query.Set("X-Amz-Algorithm", "AWS4-HMAC-SHA256")
	query.Set("X-Amz-Credential", fmt.Sprintf("%s/%s", s.accessKey, scope))
	query.Set("X-Amz-Date", amzDate)
	query.Set("X-Amz-Expires", fmt.Sprintf("%d", expires))
	query.Set("X-Amz-SignedHeaders", "host")
	if s.sessionTok != "" {
		query.Set("X-Amz-Security-Token", s.sessionTok)
	}

	canonicalQuery := query.Encode()
	canonicalRequest := strings.Join([]string{
		http.MethodGet,
		path,
		canonicalQuery,
		"host:" + host + "\n",
		"host",
		"UNSIGNED-PAYLOAD",
	}, "\n")

	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		hexSHA256(canonicalRequest),
	}, "\n")

	signature := hex.EncodeToString(signV4(s.secretKey, shortDate, s.region, s3Service, stringToSign))
	query.Set("X-Amz-Signature", signature)
	return fmt.Sprintf("https://%s%s?%s", host, path, query.Encode()), nil
}

func (s *S3) PresignedPutURL(key, contentType string) (string, error) {
	if key == "" {
		return "", fmt.Errorf("empty key")
	}
	now := time.Now().UTC()
	expires := int(s.expiry.Seconds())
	if expires < 60 {
		expires = 60
	}
	if expires > 604800 {
		expires = 604800
	}

	escapedKey := escapeS3KeyPath(key)
	host := s.host()
	path := "/" + escapedKey
	amzDate := now.Format("20060102T150405Z")
	shortDate := now.Format("20060102")
	scope := fmt.Sprintf("%s/%s/%s/aws4_request", shortDate, s.region, s3Service)

	query := url.Values{}
	query.Set("X-Amz-Algorithm", "AWS4-HMAC-SHA256")
	query.Set("X-Amz-Credential", fmt.Sprintf("%s/%s", s.accessKey, scope))
	query.Set("X-Amz-Date", amzDate)
	query.Set("X-Amz-Expires", fmt.Sprintf("%d", expires))
	query.Set("X-Amz-SignedHeaders", "content-type;host")
	if s.sessionTok != "" {
		query.Set("X-Amz-Security-Token", s.sessionTok)
	}

	if contentType == "" {
		contentType = "application/octet-stream"
	}
	canonicalQuery := query.Encode()
	canonicalRequest := strings.Join([]string{
		http.MethodPut,
		path,
		canonicalQuery,
		"content-type:" + contentType + "\n" + "host:" + host + "\n",
		"content-type;host",
		"UNSIGNED-PAYLOAD",
	}, "\n")

	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		hexSHA256(canonicalRequest),
	}, "\n")
	signature := hex.EncodeToString(signV4(s.secretKey, shortDate, s.region, s3Service, stringToSign))
	query.Set("X-Amz-Signature", signature)
	return fmt.Sprintf("https://%s%s?%s", host, path, query.Encode()), nil
}

func (s *S3) signRequest(req *http.Request, key, payloadHash string) error {
	if !s.IsConfigured() {
		return fmt.Errorf("s3 not configured")
	}

	now := time.Now().UTC()
	amzDate := now.Format("20060102T150405Z")
	shortDate := now.Format("20060102")
	scope := fmt.Sprintf("%s/%s/%s/aws4_request", shortDate, s.region, s3Service)

	host := s.host()
	req.Header.Set("Host", host)
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", payloadHash)
	if s.sessionTok != "" {
		req.Header.Set("X-Amz-Security-Token", s.sessionTok)
	}

	escapedKey := escapeS3KeyPath(key)
	canonicalURI := "/" + escapedKey
	canonicalQuery := req.URL.Query().Encode()
	canonicalHeaders := "host:" + host + "\n" + "x-amz-content-sha256:" + payloadHash + "\n" + "x-amz-date:" + amzDate + "\n"
	signedHeaders := "host;x-amz-content-sha256;x-amz-date"
	if s.sessionTok != "" {
		canonicalHeaders += "x-amz-security-token:" + s.sessionTok + "\n"
		signedHeaders += ";x-amz-security-token"
	}

	canonicalRequest := strings.Join([]string{
		req.Method,
		canonicalURI,
		canonicalQuery,
		canonicalHeaders,
		signedHeaders,
		payloadHash,
	}, "\n")

	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		hexSHA256(canonicalRequest),
	}, "\n")

	signature := hex.EncodeToString(signV4(s.secretKey, shortDate, s.region, s3Service, stringToSign))
	req.Header.Set("Authorization",
		fmt.Sprintf("AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
			s.accessKey, scope, signedHeaders, signature),
	)
	req.URL.Host = host
	req.URL.Path = canonicalURI
	req.URL.Scheme = "https"
	return nil
}

func (s *S3) objectURL(key string) string {
	escapedKey := escapeS3KeyPath(key)
	return fmt.Sprintf("https://%s/%s", s.host(), escapedKey)
}

// escapeS3KeyPath escapes each key segment while preserving path separators.
// This avoids double-encoding "/" into "%252F" during signature validation.
func escapeS3KeyPath(key string) string {
	key = strings.TrimPrefix(key, "/")
	parts := strings.Split(key, "/")
	for i, part := range parts {
		parts[i] = strings.ReplaceAll(url.PathEscape(part), "+", "%20")
	}
	return strings.Join(parts, "/")
}

func (s *S3) host() string {
	if s.region == "us-east-1" {
		return fmt.Sprintf("%s.s3.amazonaws.com", s.bucket)
	}
	return fmt.Sprintf("%s.s3.%s.amazonaws.com", s.bucket, s.region)
}

func hexSHA256(v string) string {
	sum := sha256.Sum256([]byte(v))
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
