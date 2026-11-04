package audio

import (
	"net/http"
	"testing"
	"time"
)

func TestRetryAfter(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	for _, tc := range []struct {
		value string
		want  time.Duration
	}{{"120", 120 * time.Second}, {now.Add(time.Minute).UTC().Format(http.TimeFormat), time.Minute}, {"invalid", 0}, {"-1", 0}} {
		if got := parseRetryAfter(tc.value, now); got != tc.want {
			t.Fatalf("%q: %s want %s", tc.value, got, tc.want)
		}
	}
}
