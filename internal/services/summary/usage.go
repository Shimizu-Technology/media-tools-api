package summary

import (
	"context"
	"sync/atomic"
)

type providerCallKey struct{}

// TrackProviderCall follows the request through parsing as well as I/O. HTTP
// status cannot tell whether provider work (and possibly billing) happened.
func TrackProviderCall(ctx context.Context) (context.Context, *atomic.Bool) {
	called := &atomic.Bool{}
	return context.WithValue(ctx, providerCallKey{}, called), called
}
func markProviderCall(ctx context.Context) {
	if called, ok := ctx.Value(providerCallKey{}).(*atomic.Bool); ok {
		called.Store(true)
	}
}
