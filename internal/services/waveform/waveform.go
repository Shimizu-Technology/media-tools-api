// Package waveform reduces decoded audio to real, normalized amplitude peaks.
package waveform

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
)

const DetailPeaks = 200

// Compute decodes mono 8 kHz signed PCM through a pipe. Only a 100 ms frame
// lives in RAM; its maximum is spooled as two bytes on disk. A two-hour input
// needs about 144 KB of scratch space, independent of the source codec/bitrate.
// Input is seekable so MOV/QTA files with a trailing moov atom work too.
func Compute(ctx context.Context, path string) ([]int, error) {
	scratch, err := os.CreateTemp("", "mta-waveform-peaks-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(scratch.Name())
	defer scratch.Close()
	cmd := exec.CommandContext(ctx, "ffmpeg", "-nostdin", "-v", "error", "-threads", "1", "-i", path, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "8000", "-threads", "1", "-f", "s16le", "pipe:1")
	// Do not retain unbounded ffmpeg stderr or expose source paths in errors.
	cmd.Stderr = io.Discard
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err = cmd.Start(); err != nil {
		return nil, fmt.Errorf("start waveform decoder: %w", err)
	}
	frames, maximum, readErr := spoolPeaks(ctx, pipe, scratch)
	if readErr != nil {
		_ = cmd.Process.Kill()
	}
	waitErr := cmd.Wait()
	if readErr != nil {
		return nil, readErr
	}
	if waitErr != nil {
		return nil, fmt.Errorf("waveform audio decode failed: %w", waitErr)
	}
	if frames == 0 {
		return nil, fmt.Errorf("waveform audio has no samples")
	}
	if _, err = scratch.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	raw := make([]int, DetailPeaks)
	var buf [2]byte
	for frame := int64(0); frame < frames; frame++ {
		if _, err = io.ReadFull(scratch, buf[:]); err != nil {
			return nil, err
		}
		peak := int(binary.LittleEndian.Uint16(buf[:]))
		// Include every output bin overlapped by this 100 ms frame. Very short
		// recordings repeat a measured peak instead of inventing empty intervals.
		start, end := frame*DetailPeaks/frames, ((frame+1)*DetailPeaks-1)/frames
		for bin := start; bin <= end; bin++ {
			raw[bin] = max(raw[bin], peak)
		}
	}
	denominator := math.Max(float64(maximum), 327.68) // -40 dBFS noise floor
	for i, peak := range raw {
		raw[i] = int(math.Round(100 * math.Sqrt(float64(peak)/denominator)))
	}
	return raw, nil
}

func spoolPeaks(ctx context.Context, src io.Reader, dst io.Writer) (int64, int, error) {
	var pcm [1600]byte // 800 samples = 100 ms at 8 kHz
	var encoded [2]byte
	var frames int64
	maximum := 0
	for {
		if err := ctx.Err(); err != nil {
			return 0, 0, err
		}
		n, err := io.ReadFull(src, pcm[:])
		if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
			return 0, 0, err
		}
		if n%2 != 0 {
			return 0, 0, fmt.Errorf("incomplete PCM sample")
		}
		if n == 0 {
			return frames, maximum, nil
		}
		peak := 0
		for i := 0; i < n; i += 2 {
			v := int(int16(binary.LittleEndian.Uint16(pcm[i : i+2])))
			if v < 0 {
				v = -v
			}
			peak = max(peak, v)
		}
		maximum = max(maximum, peak)
		binary.LittleEndian.PutUint16(encoded[:], uint16(peak))
		if _, err := dst.Write(encoded[:]); err != nil {
			return 0, 0, err
		}
		frames++
	}
}

// displayFloor keeps the quietest speech visible once a recording is stretched.
const displayFloor = 12

// Stretch spreads a recording's own loudness range across 0 to 100 for drawing.
// Square-root peaks of speech sit near the top, so long recordings otherwise draw
// as a solid block. It keeps every value's order and leaves silence at zero, so the
// shape stays true to the audio. Only a recording's relative loudness is meaningful,
// which was already the case: the stored peaks are normalized to its own maximum.
func Stretch(peaks []int) []int {
	if len(peaks) == 0 {
		return peaks
	}
	low, high := 0, 0
	for _, v := range peaks {
		if v > 0 && (low == 0 || v < low) {
			low = v
		}
		high = max(high, v)
	}
	result := make([]int, len(peaks))
	if high == low {
		// Silence or a perfectly level signal has no range to spread.
		copy(result, peaks)
		return result
	}
	for i, v := range peaks {
		if v > 0 {
			result[i] = displayFloor + (v-low)*(100-displayFloor)/(high-low)
		}
	}
	return result
}

// Reduce max-pools measured detail peaks into equal overlapping time ranges.
func Reduce(peaks []int, count int) []int {
	if len(peaks) == 0 || count <= 0 {
		return nil
	}
	result := make([]int, count)
	for i := range result {
		start, end := i*len(peaks)/count, ((i+1)*len(peaks)+count-1)/count
		for _, v := range peaks[start:end] {
			result[i] = max(result[i], v)
		}
	}
	return result
}
