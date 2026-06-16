package worker

import "testing"

func TestRequiresWhisperTranscodeNormalizesBrowserContainers(t *testing.T) {
	tests := []struct {
		path string
		want bool
	}{
		{path: "/tmp/recording.m4a", want: true},
		{path: "/tmp/recording.webm", want: true},
		{path: "/tmp/zoom.mp4", want: true},
		{path: "/tmp/audio.mp3", want: false},
		{path: "/tmp/audio.wav", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			if got := requiresWhisperTranscode(tt.path); got != tt.want {
				t.Fatalf("requiresWhisperTranscode(%q) = %v, want %v", tt.path, got, tt.want)
			}
		})
	}
}

func TestWhisperUploadFilenameUsesActualExtension(t *testing.T) {
	tests := []struct {
		name         string
		path         string
		originalName string
		want         string
	}{
		{
			name:         "transcoded WhatsApp mp4 uploads as mp3",
			path:         "/tmp/9e4ccf2a.mp4.whisper.mp3",
			originalName: "WhatsApp Video 2026-06-09 at 21.36.42.mp4",
			want:         "WhatsApp Video 2026-06-09 at 21.36.42.mp3",
		},
		{
			name:         "already supported mp3 stays mp3",
			path:         "/tmp/upload.mp3",
			originalName: "meeting.mp3",
			want:         "meeting.mp3",
		},
		{
			name:         "missing original base falls back to path",
			path:         "/tmp/upload.whisper.mp3",
			originalName: ".mp4",
			want:         "upload.whisper.mp3",
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
