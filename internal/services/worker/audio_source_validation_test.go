package worker

import (
	"errors"
	"strings"
	"testing"
)

func TestIsInvalidAudioSourceErrorClassifiesPermanentContainerFailures(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want bool
	}{
		{
			name: "unfinalized m4a",
			err:  errors.New("ffprobe failed: moov atom not found; Invalid data found when processing input"),
			want: true,
		},
		{
			name: "missing audio stream",
			err:  errors.New("Stream map '0:a:0' matches no streams"),
			want: true,
		},
		{
			name: "ffmpeg timeout",
			err:  errors.New("ffmpeg transcode timed out after 30m"),
			want: false,
		},
		{
			name: "tool unavailable",
			err:  errors.New("exec: ffprobe: executable file not found"),
			want: false,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if got := IsInvalidAudioSourceError(test.err); got != test.want {
				t.Fatalf("IsInvalidAudioSourceError(%q) = %t, want %t", test.err, got, test.want)
			}
		})
	}
}

func TestInvalidAudioSourcePublicMessageDoesNotExposeFFmpegDetails(t *testing.T) {
	t.Parallel()

	for _, internalDetail := range []string{"ffmpeg", "ffprobe", "moov", "/tmp/"} {
		if strings.Contains(strings.ToLower(InvalidAudioSourceMessage()), internalDetail) {
			t.Fatalf("public invalid-source message exposed %q: %q", internalDetail, InvalidAudioSourceMessage())
		}
	}
}
