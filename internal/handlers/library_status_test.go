package handlers

import "testing"

func TestValidLibraryStatus(t *testing.T) {
	tests := []struct {
		status string
		want   bool
	}{
		{status: "", want: true},
		{status: "active", want: true},
		{status: "pending", want: true},
		{status: "processing", want: true},
		{status: "completed", want: true},
		{status: "failed", want: true},
		{status: "unknown", want: false},
	}

	for _, test := range tests {
		t.Run(test.status, func(t *testing.T) {
			if got := validLibraryStatus(test.status); got != test.want {
				t.Fatalf("validLibraryStatus(%q) = %v, want %v", test.status, got, test.want)
			}
		})
	}
}
