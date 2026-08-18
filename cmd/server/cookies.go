package main

import (
	"encoding/base64"
	"fmt"
	"os"
)

// materializeCookieFile decodes an environment-provided cookie jar into a
// process-private, unpredictable temporary file. CreateTemp prevents a local
// symlink from redirecting the credential write to another path.
func materializeCookieFile(encoded string) (string, func(), error) {
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", nil, fmt.Errorf("decode cookies: %w", err)
	}

	file, err := os.CreateTemp("", "mta-yt-dlp-cookies-*.txt")
	if err != nil {
		return "", nil, fmt.Errorf("create cookie file: %w", err)
	}
	path := file.Name()
	cleanup := func() { _ = os.Remove(path) }

	if _, err := file.Write(decoded); err != nil {
		_ = file.Close()
		cleanup()
		return "", nil, fmt.Errorf("write cookie file: %w", err)
	}
	if err := file.Close(); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("close cookie file: %w", err)
	}

	return path, cleanup, nil
}
