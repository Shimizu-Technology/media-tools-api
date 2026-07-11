package webhook

import (
	"testing"
	"time"
)

func TestShutdownWaitsForActiveNotificationsAndRejectsNewOnes(t *testing.T) {
	s := &Service{
		deliveryQueue: make(chan deliveryTask),
		shutdownCh:    make(chan struct{}),
	}
	s.workerWG.Add(1)
	go s.deliveryWorker()

	if !s.beginNotification() {
		t.Fatal("expected service to accept a notification before shutdown")
	}

	shutdownDone := make(chan struct{})
	go func() {
		s.Shutdown()
		close(shutdownDone)
	}()

	// Waiting for the signal makes the ordering deterministic: Shutdown has
	// marked the service closed, but the active notification still owns its
	// notifyWG slot and therefore prevents the queue from being closed.
	<-s.shutdownCh
	select {
	case <-shutdownDone:
		t.Fatal("shutdown returned before the active notification finished")
	default:
	}

	s.notifyWG.Done()
	select {
	case <-shutdownDone:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not finish after the active notification completed")
	}

	if s.beginNotification() {
		t.Fatal("expected service to reject notifications after shutdown")
	}
}
