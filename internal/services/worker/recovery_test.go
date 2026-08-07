package worker

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestSignalWorkersWakesImmediately(t *testing.T) {
	pool := NewPool(1, 1, nil, nil, nil)
	pool.signalWorkers()

	select {
	case <-pool.wake:
	default:
		t.Fatal("signalWorkers did not make a wake signal immediately available")
	}
}

func TestSubmitSignalsWorkerWhenPayloadRefreshFails(t *testing.T) {
	pool := NewPool(1, 1, nil, nil, nil)
	pool.enqueueBackgroundJob = func(context.Context, string, string, []byte) (bool, error) {
		return false, errors.New("database temporarily unavailable")
	}

	err := pool.Submit(Job{ID: "resource-id", Type: JobTranscriptExtraction})
	if err == nil {
		t.Fatal("Submit returned nil error, want persistence refresh failure")
	}
	select {
	case <-pool.wake:
	default:
		t.Fatal("Submit did not wake a worker after the payload refresh failed")
	}
}

func TestSubmitBlockingSignalsWorkerWhenPayloadRefreshFails(t *testing.T) {
	pool := NewPool(1, 1, nil, nil, nil)
	pool.enqueueBackgroundJob = func(context.Context, string, string, []byte) (bool, error) {
		return false, errors.New("database temporarily unavailable")
	}

	err := pool.SubmitBlocking(context.Background(), Job{ID: "resource-id", Type: JobTranscriptExtraction})
	if err == nil {
		t.Fatal("SubmitBlocking returned nil error, want persistence refresh failure")
	}
	select {
	case <-pool.wake:
	default:
		t.Fatal("SubmitBlocking did not wake a worker after the payload refresh failed")
	}
}

func TestStartProbesDurableQueueWithEveryWorker(t *testing.T) {
	const workers = 3
	pool := NewPool(workers, 1, nil, nil, nil)
	claims := make(chan struct{}, workers)
	pool.claimBackgroundJob = func(context.Context, string, time.Duration) (*models.BackgroundJob, error) {
		claims <- struct{}{}
		return nil, nil
	}
	pool.Start()
	t.Cleanup(pool.Stop)

	for i := 0; i < workers; i++ {
		select {
		case <-claims:
		case <-time.After(500 * time.Millisecond):
			t.Fatalf("startup delivered %d initial claim attempts, want %d", i, workers)
		}
	}
}

func TestWorkerDoesNotPollDatabaseWhileIdle(t *testing.T) {
	pool := NewPool(1, 1, nil, nil, nil)
	claims := make(chan struct{}, 2)
	pool.claimBackgroundJob = func(context.Context, string, time.Duration) (*models.BackgroundJob, error) {
		claims <- struct{}{}
		return nil, nil
	}
	pool.Start()
	t.Cleanup(pool.Stop)

	select {
	case <-claims:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("worker did not perform its startup durable-queue claim")
	}

	select {
	case <-claims:
		t.Fatal("idle worker performed an unprompted database claim")
	case <-time.After(50 * time.Millisecond):
	}
}

func TestWorkerWakesAtInheritedLeaseExpiry(t *testing.T) {
	pool := NewPool(1, 1, nil, nil, nil)
	pool.leaseRecoveryGrace = time.Millisecond
	claims := make(chan int, 2)
	attempt := 0
	pool.claimBackgroundJob = func(context.Context, string, time.Duration) (*models.BackgroundJob, error) {
		attempt++
		claims <- attempt
		return nil, nil
	}
	lookup := 0
	pool.nextBackgroundJobWake = func(context.Context) (*time.Time, error) {
		lookup++
		if lookup == 1 {
			next := time.Now().Add(10 * time.Millisecond)
			return &next, nil
		}
		return nil, nil
	}
	pool.Start()
	t.Cleanup(pool.Stop)

	for want := 1; want <= 2; want++ {
		select {
		case got := <-claims:
			if got != want {
				t.Fatalf("claim attempt = %d, want %d", got, want)
			}
		case <-time.After(500 * time.Millisecond):
			t.Fatalf("timed out waiting for inherited-lease claim attempt %d", want)
		}
	}
}

func TestWorkerRetriesTransientClaimFailure(t *testing.T) {
	pool := NewPool(1, 1, nil, nil, nil)
	pool.claimRetryInitialDelay = time.Millisecond
	pool.claimRetryMaxDelay = 5 * time.Millisecond
	claims := make(chan int, 3)
	attempt := 0
	pool.claimBackgroundJob = func(context.Context, string, time.Duration) (*models.BackgroundJob, error) {
		attempt++
		claims <- attempt
		if attempt == 1 {
			return nil, errors.New("temporary connection failure")
		}
		return nil, nil
	}
	pool.Start()
	t.Cleanup(pool.Stop)

	for want := 1; want <= 2; want++ {
		select {
		case got := <-claims:
			if got != want {
				t.Fatalf("claim attempt = %d, want %d", got, want)
			}
		case <-time.After(500 * time.Millisecond):
			t.Fatalf("timed out waiting for claim attempt %d", want)
		}
	}
}

func TestWorkerSupervisorRestartsAfterInfrastructurePanic(t *testing.T) {
	pool := NewPool(1, 1, nil, nil, nil)
	claims := make(chan int, 2)
	attempt := 0
	pool.claimBackgroundJob = func(context.Context, string, time.Duration) (*models.BackgroundJob, error) {
		attempt++
		claims <- attempt
		if attempt == 1 {
			panic("unexpected database panic")
		}
		return nil, nil
	}
	pool.Start()
	t.Cleanup(pool.Stop)

	for want := 1; want <= 2; want++ {
		select {
		case got := <-claims:
			if got != want {
				t.Fatalf("claim attempt = %d, want %d", got, want)
			}
		case <-time.After(500 * time.Millisecond):
			t.Fatalf("timed out waiting for claim attempt %d", want)
		}
	}
}

func TestLeaseRecoverySignalsAtConfirmedExpiry(t *testing.T) {
	pool := NewPool(1, 1, nil, nil, nil)
	pool.leaseDuration = 10 * time.Millisecond
	pool.leaseRecoveryGrace = 0
	recovery := pool.startLeaseRecoverySignal()
	t.Cleanup(func() {
		recovery.stopSignaling()
		pool.Stop()
	})

	select {
	case <-pool.wake:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("lease expiry did not signal a worker")
	}
}

func TestLeaseRecoveryRenewalPostponesSignal(t *testing.T) {
	pool := NewPool(1, 1, nil, nil, nil)
	pool.leaseDuration = 80 * time.Millisecond
	pool.leaseRecoveryGrace = 0
	recovery := pool.startLeaseRecoverySignal()
	t.Cleanup(func() {
		recovery.stopSignaling()
		pool.Stop()
	})

	time.Sleep(40 * time.Millisecond)
	recovery.renewLease()
	select {
	case <-pool.wake:
		t.Fatal("lease recovery signal fired before the renewed lease expired")
	case <-time.After(60 * time.Millisecond):
	}

	select {
	case <-pool.wake:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("renewed lease expiry did not eventually signal a worker")
	}
}

func TestLeaseRecoveryStopsAfterDurableAcknowledgement(t *testing.T) {
	pool := NewPool(1, 1, nil, nil, nil)
	pool.leaseDuration = 10 * time.Millisecond
	pool.leaseRecoveryGrace = 0
	recovery := pool.startLeaseRecoverySignal()
	recovery.stopSignaling()
	t.Cleanup(pool.Stop)

	select {
	case <-pool.wake:
		t.Fatal("stopped lease recovery signal woke a worker")
	case <-time.After(30 * time.Millisecond):
	}
}

func TestNewPoolWakeBufferFitsEveryWorker(t *testing.T) {
	pool := NewPool(3, 1, nil, nil, nil)
	if cap(pool.wake) != 3 {
		t.Fatalf("wake buffer capacity = %d, want 3", cap(pool.wake))
	}
}

func TestNextClaimRetryDelayCapsAtMaximum(t *testing.T) {
	const maximum = 30 * time.Second
	for _, test := range []struct {
		current time.Duration
		want    time.Duration
	}{
		{current: 250 * time.Millisecond, want: 500 * time.Millisecond},
		{current: 16 * time.Second, want: maximum},
		{current: maximum, want: maximum},
	} {
		if got := nextClaimRetryDelay(test.current, maximum); got != test.want {
			t.Fatalf("nextClaimRetryDelay(%s) = %s, want %s", test.current, got, test.want)
		}
	}
}
