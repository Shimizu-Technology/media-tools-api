package account

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/bcrypt"
	"golang.org/x/text/unicode/norm"
)

const (
	passwordMemory      uint32 = 19 * 1024
	passwordIterations  uint32 = 2
	passwordParallelism uint8  = 1
	passwordSaltLength         = 16
	passwordKeyLength   uint32 = 32

	maxPasswordMemory      uint64 = 256 * 1024
	maxPasswordIterations  uint64 = 10
	maxPasswordParallelism uint64 = 4
	maxSaltLength                 = 64
	maxKeyLength                  = 64
)

var (
	ErrPasswordInvalid = errors.New("password must be 15 to 128 characters")
	ErrHashInvalid     = errors.New("password hash is invalid")
)

// PasswordVerification reports whether a password matched and whether the
// stored representation should be upgraded after a successful verification.
type PasswordVerification struct {
	Valid       bool
	NeedsRehash bool
}

// PasswordHasher bounds memory-hard work for the whole process. Argon2id is
// intentionally expensive; without a shared cap a burst of login attempts can
// exhaust a small Render instance before HTTP rate limiting takes effect.
type PasswordHasher struct {
	semaphore       chan struct{}
	dummyHash       string
	dummyBcryptHash string
}

func NewPasswordHasher(maxConcurrent int) (*PasswordHasher, error) {
	if maxConcurrent < 1 {
		maxConcurrent = 1
	}
	h := &PasswordHasher{semaphore: make(chan struct{}, maxConcurrent)}
	dummy, err := h.Hash(context.Background(), "dummy-password-never-used")
	if err != nil {
		return nil, fmt.Errorf("create dummy password hash: %w", err)
	}
	h.dummyHash = dummy
	dummyBcrypt, err := bcrypt.GenerateFromPassword([]byte("dummy-password-never-used"), bcrypt.DefaultCost)
	if err != nil {
		return nil, fmt.Errorf("create dummy bcrypt hash: %w", err)
	}
	h.dummyBcryptHash = string(dummyBcrypt)
	return h, nil
}

// NormalizeNewPassword applies NFC once before validation and storage. Login
// applies the same normalization so visually identical Unicode passwords do
// not become different credentials on different Apple keyboards.
func NormalizeNewPassword(password string) (string, error) {
	if !utf8.ValidString(password) || len(password) > 1024 {
		return "", ErrPasswordInvalid
	}
	normalized := norm.NFC.String(password)
	count := utf8.RuneCountInString(normalized)
	if count < 15 || count > 128 {
		return "", ErrPasswordInvalid
	}
	return normalized, nil
}

func NormalizePasswordForLogin(password string) (string, bool) {
	if !utf8.ValidString(password) || len(password) == 0 || len(password) > 1024 {
		return "", false
	}
	// Legacy bcrypt credentials were created from the exact submitted bytes.
	// Preserve those bytes for verification; Verify applies NFC only to the
	// first-party Argon2id path, and a successful bcrypt login rehashes NFC.
	return password, true
}

func NormalizeVerifiedPassword(password string) string { return norm.NFC.String(password) }

func (h *PasswordHasher) acquire(ctx context.Context) error {
	select {
	case h.semaphore <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (h *PasswordHasher) release() { <-h.semaphore }

func (h *PasswordHasher) Hash(ctx context.Context, password string) (string, error) {
	if err := h.acquire(ctx); err != nil {
		return "", err
	}
	defer h.release()

	salt := make([]byte, passwordSaltLength)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("generate password salt: %w", err)
	}
	key := argon2.IDKey([]byte(password), salt, passwordIterations, passwordMemory, passwordParallelism, passwordKeyLength)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, passwordMemory, passwordIterations, passwordParallelism,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(key)), nil
}

func (h *PasswordHasher) Verify(ctx context.Context, encoded, password string) (PasswordVerification, error) {
	if strings.HasPrefix(encoded, "$2a$") || strings.HasPrefix(encoded, "$2b$") || strings.HasPrefix(encoded, "$2y$") {
		if err := h.acquire(ctx); err != nil {
			return PasswordVerification{}, err
		}
		err := bcrypt.CompareHashAndPassword([]byte(encoded), []byte(password))
		h.release()
		// Unknown accounts and Argon2id accounts perform both bounded primitives
		// too, keeping legacy-account timing from becoming an email oracle.
		if _, paddingErr := h.verifyArgon2(ctx, h.dummyHash, NormalizeVerifiedPassword(password)); paddingErr != nil {
			return PasswordVerification{}, paddingErr
		}
		if errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
			return PasswordVerification{}, nil
		}
		if err != nil {
			return PasswordVerification{}, ErrHashInvalid
		}
		return PasswordVerification{Valid: true, NeedsRehash: true}, nil
	}

	verification, err := h.verifyArgon2(ctx, encoded, NormalizeVerifiedPassword(password))
	if err != nil {
		return PasswordVerification{}, err
	}
	if err := h.acquire(ctx); err != nil {
		return PasswordVerification{}, err
	}
	_ = bcrypt.CompareHashAndPassword([]byte(h.dummyBcryptHash), []byte(password))
	h.release()
	return verification, nil
}

func (h *PasswordHasher) verifyArgon2(ctx context.Context, encoded, password string) (PasswordVerification, error) {
	params, salt, expected, err := parseArgon2id(encoded)
	if err != nil {
		return PasswordVerification{}, err
	}
	if err := h.acquire(ctx); err != nil {
		return PasswordVerification{}, err
	}
	actual := argon2.IDKey([]byte(password), salt, params.iterations, params.memory, params.parallelism, uint32(len(expected)))
	h.release()
	valid := subtle.ConstantTimeCompare(actual, expected) == 1
	return PasswordVerification{
		Valid:       valid,
		NeedsRehash: valid && (params.memory != passwordMemory || params.iterations != passwordIterations || params.parallelism != passwordParallelism || len(expected) != int(passwordKeyLength)),
	}, nil
}

// VerifyDummy performs the same bounded Argon2 work for unknown/passwordless
// accounts so response time does not reveal whether an email address exists.
func (h *PasswordHasher) VerifyDummy(ctx context.Context, password string) error {
	_, err := h.Verify(ctx, h.dummyHash, password)
	return err
}

type argon2Params struct {
	memory      uint32
	iterations  uint32
	parallelism uint8
}

func parseArgon2id(encoded string) (argon2Params, []byte, []byte, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" || parts[2] != "v=19" {
		return argon2Params{}, nil, nil, ErrHashInvalid
	}
	values := strings.Split(parts[3], ",")
	if len(values) != 3 {
		return argon2Params{}, nil, nil, ErrHashInvalid
	}
	read := func(value, prefix string, max uint64) (uint64, error) {
		if !strings.HasPrefix(value, prefix) {
			return 0, ErrHashInvalid
		}
		n, err := strconv.ParseUint(strings.TrimPrefix(value, prefix), 10, 32)
		if err != nil || n < 1 || n > max {
			return 0, ErrHashInvalid
		}
		return n, nil
	}
	memory, err := read(values[0], "m=", maxPasswordMemory)
	if err != nil {
		return argon2Params{}, nil, nil, err
	}
	iterations, err := read(values[1], "t=", maxPasswordIterations)
	if err != nil {
		return argon2Params{}, nil, nil, err
	}
	parallelism, err := read(values[2], "p=", maxPasswordParallelism)
	if err != nil {
		return argon2Params{}, nil, nil, err
	}
	salt, err := base64.RawStdEncoding.Strict().DecodeString(parts[4])
	if err != nil || len(salt) < 8 || len(salt) > maxSaltLength {
		return argon2Params{}, nil, nil, ErrHashInvalid
	}
	key, err := base64.RawStdEncoding.Strict().DecodeString(parts[5])
	if err != nil || len(key) < 16 || len(key) > maxKeyLength {
		return argon2Params{}, nil, nil, ErrHashInvalid
	}
	return argon2Params{uint32(memory), uint32(iterations), uint8(parallelism)}, salt, key, nil
}
