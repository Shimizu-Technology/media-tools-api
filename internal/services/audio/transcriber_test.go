package audio

import "testing"

func TestWhisperContentType(t *testing.T) {
	tests := []struct {
		filename string
		want     string
	}{
		{filename: "recording.mp3", want: "audio/mpeg"},
		{filename: "clip.M4A", want: "audio/mp4"},
		{filename: "video.mp4", want: "video/mp4"},
		{filename: "voice.ogg", want: "audio/ogg"},
		{filename: "meeting.wav", want: "audio/wav"},
		{filename: "unknown.bin", want: "application/octet-stream"},
	}

	for _, tt := range tests {
		t.Run(tt.filename, func(t *testing.T) {
			if got := whisperContentType(tt.filename); got != tt.want {
				t.Fatalf("whisperContentType() = %q, want %q", got, tt.want)
			}
		})
	}
}
