package account

import (
	"context"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestPasswordHasherRoundTripAndUniqueSalt(t *testing.T) {
	h, err := NewPasswordHasher(2)
	if err != nil {
		t.Fatal(err)
	}
	password := "correct horse battery staple"
	first, err := h.Hash(context.Background(), password)
	if err != nil {
		t.Fatal(err)
	}
	second, err := h.Hash(context.Background(), password)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("hashes reused a salt")
	}
	verified, err := h.Verify(context.Background(), first, password)
	if err != nil || !verified.Valid || verified.NeedsRehash {
		t.Fatalf("verify = %#v, %v", verified, err)
	}
	wrong, err := h.Verify(context.Background(), first, password+"!")
	if err != nil || wrong.Valid {
		t.Fatalf("wrong verify = %#v, %v", wrong, err)
	}
}

func TestPasswordHasherAcceptsAndUpgradesBcrypt(t *testing.T) {
	h, err := NewPasswordHasher(1)
	if err != nil {
		t.Fatal(err)
	}
	hash, err := bcrypt.GenerateFromPassword([]byte("legacy-password-value"), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	verified, err := h.Verify(context.Background(), string(hash), "legacy-password-value")
	if err != nil || !verified.Valid || !verified.NeedsRehash {
		t.Fatalf("verify = %#v, %v", verified, err)
	}
}

func TestPasswordHasherPreservesLegacyBcryptBytesThenNormalizesUpgrade(t *testing.T) {
	h, err := NewPasswordHasher(1)
	if err != nil {
		t.Fatal(err)
	}
	decomposed := "legacy-password-e\u0301"
	hash, err := bcrypt.GenerateFromPassword([]byte(decomposed), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	login, ok := NormalizePasswordForLogin(decomposed)
	if !ok {
		t.Fatal("legacy password rejected")
	}
	verified, err := h.Verify(context.Background(), string(hash), login)
	if err != nil || !verified.Valid || !verified.NeedsRehash {
		t.Fatalf("verify = %#v, %v", verified, err)
	}
	if got := NormalizeVerifiedPassword(login); got != "legacy-password-é" {
		t.Fatalf("upgrade normalization = %q", got)
	}
}

func TestPasswordHasherRejectsMalformedOrOversizedPHC(t *testing.T) {
	h, err := NewPasswordHasher(1)
	if err != nil {
		t.Fatal(err)
	}
	for _, encoded := range []string{
		"", "$argon2id$v=19$m=999999,t=2,p=1$c2FsdHNhbHQ$aGFzaGhhc2hoYXNoaGFzaA",
		"$argon2id$v=19$m=19456,t=99,p=1$c2FsdHNhbHQ$aGFzaGhhc2hoYXNoaGFzaA",
		"$argon2id$v=19$m=19456,t=2,p=9$c2FsdHNhbHQ$aGFzaGhhc2hoYXNoaGFzaA",
	} {
		if _, err := h.Verify(context.Background(), encoded, "anything"); err == nil {
			t.Fatalf("Verify(%q) succeeded", encoded)
		}
	}
}

func TestNormalizeNewPassword(t *testing.T) {
	if _, err := NormalizeNewPassword(strings.Repeat("a", 14)); err == nil {
		t.Fatal("accepted 14 characters")
	}
	if got, err := NormalizeNewPassword(strings.Repeat("a", 15)); err != nil || len(got) != 15 {
		t.Fatalf("15 chars = %q, %v", got, err)
	}
	if _, err := NormalizeNewPassword(strings.Repeat("a", 128)); err != nil {
		t.Fatal(err)
	}
	if _, err := NormalizeNewPassword(strings.Repeat("a", 129)); err == nil {
		t.Fatal("accepted 129 characters")
	}
	if got, err := NormalizeNewPassword("  a long password with spaces  "); err != nil || got != "  a long password with spaces  " {
		t.Fatalf("spaces changed: %q, %v", got, err)
	}
	if got, err := NormalizeNewPassword("12345678901234e\u0301"); err != nil || got != "12345678901234é" {
		t.Fatalf("NFC = %q, %v", got, err)
	}
}
