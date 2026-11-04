package waveform

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func generate(t *testing.T, path, filter string, format ...string) {
	t.Helper()
	args := []string{"-v", "error", "-f", "lavfi", "-i", filter, "-threads", "1"}
	args = append(args, format...)
	args = append(args, path)
	if output, err := exec.Command("ffmpeg", args...).CombinedOutput(); err != nil {
		t.Fatalf("fixture: %v %s", err, output)
	}
}

func TestComputeRealAudioSilenceQTAAndCorruption(t *testing.T) {
	dir := t.TempDir()
	ctx := context.Background()
	silence := filepath.Join(dir, "silence.wav")
	generate(t, silence, "anullsrc=r=8000:cl=mono:d=2")
	peaks, err := Compute(ctx, silence)
	if err != nil {
		t.Fatal(err)
	}
	if len(peaks) != 200 {
		t.Fatal(len(peaks))
	}
	for _, v := range peaks {
		if v != 0 {
			t.Fatal("silence invented a peak")
		}
	}
	qta := filepath.Join(dir, "shared.qta")
	// MOV with a trailing moov atom, as in old Voice Memos shares.
	generate(t, qta, "aevalsrc=if(lt(t\\,1)\\,0\\,0.1*sin(440*2*PI*t)):s=8000:d=4", "-c:a", "aac", "-f", "mov")
	peaks, err = Compute(ctx, qta)
	if err != nil {
		t.Fatal(err)
	}
	quiet, loud := 0, 0
	for i, v := range peaks {
		if v < 0 || v > 100 {
			t.Fatal(v)
		}
		if i < 40 {
			quiet += v
		}
		if i > 70 {
			loud += v
		}
	}
	if quiet > 0 || loud == 0 {
		t.Fatalf("silence=%d speech=%d", quiet, loud)
	}
	if row := Reduce(peaks, 32); len(row) != 32 {
		t.Fatal(len(row))
	}
	corrupt := filepath.Join(dir, "corrupt.mov")
	os.WriteFile(corrupt, []byte("not a media file"), 0600)
	if _, err := Compute(ctx, corrupt); err == nil {
		t.Fatal("corrupt input succeeded")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := Compute(cancelled, qta); err == nil {
		t.Fatal("canceled decode succeeded")
	}
}

// Optional measured fixture: ordinary CI uses short real media above. Run a
// compiled test binary with MTA_WAVEFORM_LONG=1 to profile Go + ffmpeg RSS.
func TestLongStreamingMemory(t *testing.T) {
	if os.Getenv("MTA_WAVEFORM_LONG") == "" {
		t.Skip("opt-in two-hour measured fixture")
	}
	path := filepath.Join(t.TempDir(), "two-hours.qta")
	generate(t, path, "aevalsrc=if(lt(mod(t\\,10)\\,2)\\,0\\,0.08*sin(440*2*PI*t)):s=8000:d=7200", "-c:a", "pcm_s16le", "-f", "mov")
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	started := time.Now()
	peaks, err := Compute(context.Background(), path)
	elapsed := time.Since(started)
	runtime.ReadMemStats(&after)
	if err != nil || len(peaks) != 200 {
		t.Fatalf("peaks=%d err=%v", len(peaks), err)
	}
	allocated := after.TotalAlloc - before.TotalAlloc
	if allocated > 8<<20 {
		t.Fatalf("waveform allocated %d bytes; expected bounded buffers", allocated)
	}
	t.Logf("7200s MOV: elapsed=%s total_go_allocated=%d heap_in_use=%d peak_count=%d", elapsed, allocated, after.HeapInuse, len(peaks))
}
