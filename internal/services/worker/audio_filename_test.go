package worker

import "testing"

func TestWhisperUploadFilenameUsesActualExtension(t *testing.T) {
	tests := []struct {
		name         string
		path         string
		originalName string
		want         string
	}{
		{
			name:         "transcoded WhatsApp mp4 uploads as ogg",
			path:         "/tmp/9e4ccf2a.mp4.whisper.ogg",
			originalName: "WhatsApp Video 2026-06-09 at 21.36.42.mp4",
			want:         "WhatsApp Video 2026-06-09 at 21.36.42.ogg",
		},
		{
			name:         "already supported mp3 stays mp3",
			path:         "/tmp/upload.mp3",
			originalName: "meeting.mp3",
			want:         "meeting.mp3",
		},
		{
			name:         "missing original base falls back to path",
			path:         "/tmp/upload.whisper.ogg",
			originalName: ".mp4",
			want:         "upload.whisper.ogg",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := whisperUploadFilename(tt.path, tt.originalName); got != tt.want {
				t.Fatalf("whisperUploadFilename() = %q, want %q", got, tt.want)
			}
		})
	}
}
