package audio

import (
	"bytes"
	"mime/multipart"
	"strings"
	"testing"
)

func TestWhisperContentType(t *testing.T) {
	tests := []struct {
		filename string
		want     string
	}{
		{filename: "recording.mp3", want: "audio/mpeg"},
		{filename: "audio.mpga", want: "audio/mpeg"},
		{filename: "program.mpeg", want: "video/mpeg"},
		{filename: "raw.aac", want: "audio/aac"},
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

func TestWriteTranscriptionMultipartStreamsAudioAndVerboseTimingFields(t *testing.T) {
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	boundary := writer.Boundary()
	if err := writeTranscriptionMultipart(
		writer,
		strings.NewReader("audio-bytes"),
		`meeting "notes".mp3`,
		"whisper-1",
		"en",
		"Product names",
	); err != nil {
		t.Fatalf("writeTranscriptionMultipart() error = %v", err)
	}

	reader := multipart.NewReader(bytes.NewReader(body.Bytes()), boundary)
	fields := map[string]string{}
	for {
		part, err := reader.NextPart()
		if err != nil {
			break
		}
		var value bytes.Buffer
		_, _ = value.ReadFrom(part)
		if part.FormName() == "file" {
			if part.FileName() != `meeting "notes".mp3` {
				t.Fatalf("filename = %q, want escaped original name", part.FileName())
			}
			if value.String() != "audio-bytes" {
				t.Fatalf("file body = %q, want streamed audio", value.String())
			}
			continue
		}
		fields[part.FormName()] = value.String()
	}
	if fields["model"] != "whisper-1" ||
		fields["language"] != "en" ||
		fields["prompt"] != "Product names" ||
		fields["response_format"] != "verbose_json" {
		t.Fatalf("multipart fields = %#v, want model, language, prompt, and verbose timing", fields)
	}
}
