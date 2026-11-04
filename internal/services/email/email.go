// Package email keeps credentials out of logs and durable job payloads.
package email

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"strconv"
	"time"
)

type Message struct {
	To      string `json:"to"`
	Subject string `json:"subject"`
	Text    string `json:"text"`
}

type Service struct {
	Mode   string
	Key    string
	From   string
	Client *http.Client
	aead   cipher.AEAD
	pepper []byte
}

// JWT_SECRET already has a production strength startup gate. Domain separation
// gives email encryption and low-entropy code hashing independent derived keys.
// Rotating that secret intentionally invalidates pending codes and email jobs.
func New(mode, key, from, secret string) (*Service, error) {
	if mode == "" {
		mode = "log"
	}
	if mode != "log" && mode != "resend" {
		return nil, errors.New("EMAIL_DELIVERY must be log or resend")
	}
	if mode == "resend" && (key == "" || from == "") {
		return nil, errors.New("Resend delivery needs key and sender")
	}
	digest := sha256.Sum256([]byte("media-tools/email-encryption/v1:" + secret))
	block, err := aes.NewCipher(digest[:])
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	pepper := sha256.Sum256([]byte("media-tools/email-code/v1:" + secret))
	return &Service{Mode: mode, Key: key, From: from, Client: &http.Client{Timeout: 10 * time.Second}, aead: aead, pepper: pepper[:]}, nil
}

func NewCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func (s *Service) CodeHash(id, code string) string {
	m := hmac.New(sha256.New, s.pepper)
	_, _ = m.Write([]byte(id + ":" + code))
	return hex.EncodeToString(m.Sum(nil))
}

func (s *Service) Seal(message Message) (string, error) {
	raw, err := json.Marshal(message)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(s.aead.Seal(nonce, nonce, raw, []byte("auth-email-v1"))), nil
}

func (s *Service) Open(sealed string) (Message, error) {
	var message Message
	raw, err := base64.RawURLEncoding.DecodeString(sealed)
	if err != nil || len(raw) < s.aead.NonceSize() {
		return message, errors.New("invalid encrypted email")
	}
	plain, err := s.aead.Open(nil, raw[:s.aead.NonceSize()], raw[s.aead.NonceSize():], []byte("auth-email-v1"))
	if err != nil {
		return message, errors.New("invalid encrypted email")
	}
	if err := json.Unmarshal(plain, &message); err != nil {
		return message, errors.New("invalid email payload")
	}
	return message, nil
}

type DeliveryError struct {
	Status     int
	RetryAfter time.Duration
}

func (e *DeliveryError) Error() string   { return fmt.Sprintf("email provider status %d", e.Status) }
func (e *DeliveryError) Retryable() bool { return e.Status == 0 || e.Status == 429 || e.Status >= 500 }

// Deliver follows Resend's REST contract. Never include the response body or
// transport error in logs: either may echo an address, credential, or code.
// The stable outbox UUID is also the provider idempotency key on every retry.
func (s *Service) Deliver(ctx context.Context, id, sealed string) error {
	message, err := s.Open(sealed)
	if err != nil {
		return err
	}
	if s.Mode == "log" {
		log.Printf("auth email suppressed (delivery=log, job=%s)", id)
		return nil
	}
	body, err := json.Marshal(struct {
		From    string   `json:"from"`
		To      []string `json:"to"`
		Subject string   `json:"subject"`
		Text    string   `json:"text"`
	}{s.From, []string{message.To}, message.Subject, message.Text})
	if err != nil {
		return errors.New("encode email")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.resend.com/emails", bytes.NewReader(body))
	if err != nil {
		return errors.New("prepare email request")
	}
	req.Header.Set("Authorization", "Bearer "+s.Key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", "auth-email/"+id)
	resp, err := s.Client.Do(req)
	if err != nil {
		return &DeliveryError{}
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 16384))
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	delay := 30 * time.Second
	if seconds, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && seconds > 0 {
		delay = time.Duration(min(seconds, 3600)) * time.Second
	} else if date, err := http.ParseTime(resp.Header.Get("Retry-After")); err == nil && time.Until(date) > 0 {
		delay = min(time.Until(date), time.Hour)
	}
	return &DeliveryError{Status: resp.StatusCode, RetryAfter: delay}
}

func CodeMessage(to, code, purpose string) Message {
	label := map[string]string{"signup": "sign-up", "reset": "password reset", "email_change": "email change", "verify": "email verification"}[purpose]
	if label == "" {
		label = "verification"
	}
	return Message{To: to, Subject: "Your Media Tools code", Text: "Your Media Tools " + label + " code is " + code + ". It expires in 10 minutes. If you did not request this, ignore this email."}
}
func Notice(to, action string) Message {
	return Message{To: to, Subject: "Media Tools account updated", Text: "Your Media Tools " + action + " was changed. If this was not you, reset your password and contact support."}
}
