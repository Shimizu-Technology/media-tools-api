package account

import (
	"bufio"
	"context"
	"crypto/sha1" // HIBP uses SHA-1 only for a lookup prefix, never password storage.
	"encoding/hex"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type PwnedChecker struct{ Client *http.Client }

func NewPwnedChecker() *PwnedChecker {
	return &PwnedChecker{Client: &http.Client{Timeout: 3 * time.Second}}
}

// Compromised sends only the first five hex characters, with padding requested.
// An outage or malformed response fails open; passwords and full hashes never
// leave this process. Source: https://haveibeenpwned.com/API/v3#PwnedPasswords
func (p *PwnedChecker) Compromised(ctx context.Context, password string) bool {
	digest := sha1.Sum([]byte(password))
	value := strings.ToUpper(hex.EncodeToString(digest[:]))
	req, err := http.NewRequestWithContext(ctx, "GET", "https://api.pwnedpasswords.com/range/"+value[:5], nil)
	if err != nil {
		return false
	}
	req.Header.Set("Add-Padding", "true")
	req.Header.Set("User-Agent", "Media-Tools-Password-Check")
	resp, err := p.Client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	scan := bufio.NewScanner(io.LimitReader(resp.Body, 2<<20))
	for scan.Scan() {
		suffix, count, ok := strings.Cut(strings.TrimSpace(scan.Text()), ":")
		if !ok {
			continue
		}
		n, err := strconv.Atoi(count)
		if err == nil && n > 0 && strings.EqualFold(suffix, value[5:]) {
			return true
		}
	}
	return false
}
