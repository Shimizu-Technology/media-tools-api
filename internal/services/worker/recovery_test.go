package worker

import (
	"testing"
	"time"
)

func TestSignalWorkersWakesImmediately(t *testing.T) {
	pool := NewPool(1, 1, time.Hour, nil, nil, nil)
	pool.signalWorkers()

	select {
	case <-pool.wake:
	default:
		t.Fatal("signalWorkers did not make a wake signal immediately available")
	}
}

func TestRecoverySweepSignalsEveryWorker(t *testing.T) {
	const workers = 3
	pool := NewPool(workers, 1, 5*time.Millisecond, nil, nil, nil)
	pool.wg.Add(1)
	go pool.recoverMissedWakeups()

	for i := 0; i < workers; i++ {
		select {
		case <-pool.wake:
		case <-time.After(500 * time.Millisecond):
			pool.cancel()
			pool.wg.Wait()
			t.Fatalf("recovery sweep delivered %d signals, want %d", i, workers)
		}
	}

	pool.cancel()
	pool.wg.Wait()
}

func TestNewPoolWakeBufferFitsEveryWorker(t *testing.T) {
	pool := NewPool(3, 1, time.Hour, nil, nil, nil)
	if cap(pool.wake) != 3 {
		t.Fatalf("wake buffer capacity = %d, want 3", cap(pool.wake))
	}
}

func TestNewPoolDefaultsInvalidRecoveryInterval(t *testing.T) {
	pool := NewPool(1, 1, 0, nil, nil, nil)
	if pool.recoveryInterval != defaultRecoveryInterval {
		t.Fatalf("recoveryInterval = %s, want %s", pool.recoveryInterval, defaultRecoveryInterval)
	}
}
