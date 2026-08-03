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

func TestRecoverySweepSignalsWorker(t *testing.T) {
	pool := NewPool(1, 1, 5*time.Millisecond, nil, nil, nil)
	pool.wg.Add(1)
	go pool.recoverMissedWakeups()

	select {
	case <-pool.wake:
	case <-time.After(500 * time.Millisecond):
		pool.cancel()
		pool.wg.Wait()
		t.Fatal("recovery sweep did not signal a worker")
	}

	pool.cancel()
	pool.wg.Wait()
}

func TestNewPoolDefaultsInvalidRecoveryInterval(t *testing.T) {
	pool := NewPool(1, 1, 0, nil, nil, nil)
	if pool.recoveryInterval != defaultRecoveryInterval {
		t.Fatalf("recoveryInterval = %s, want %s", pool.recoveryInterval, defaultRecoveryInterval)
	}
}
