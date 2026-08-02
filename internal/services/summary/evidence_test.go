package summary

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func TestValidateCitedOutputDropsInventedAndDuplicateCitationIDs(t *testing.T) {
	segments := []EvidenceSegment{{ID: "known-1"}, {ID: "known-2"}}
	output := citedOutput{
		Summary: citedClaim{
			Text:      "Supported summary",
			Citations: []string{"known-1", "invented", "known-1"},
		},
		KeyPoints: []citedClaim{
			{Text: "Point", Citations: []string{"known-2", "unknown"}},
			{Text: "Unsupported point", Citations: []string{"unknown"}},
			{Text: "  ", Citations: []string{"known-1"}},
		},
	}

	got := validateCitedOutput(output, segments)
	if len(got.Summary.Citations) != 1 || got.Summary.Citations[0] != "known-1" {
		t.Fatalf("summary citations = %#v, want only known-1", got.Summary.Citations)
	}
	if len(got.KeyPoints) != 1 || len(got.KeyPoints[0].Citations) != 1 ||
		got.KeyPoints[0].Citations[0] != "known-2" {
		t.Fatalf("key point citations = %#v, want only known-2", got.KeyPoints)
	}
}

func TestRequireCitedOutputRejectsUnsupportedSummary(t *testing.T) {
	err := requireCitedOutput(citedOutput{
		Summary: citedClaim{Text: "A claim with no validated citation"},
	})
	if err == nil {
		t.Fatal("requireCitedOutput() error = nil, want unsupported summary error")
	}
}

func TestSplitEvidenceBatchesRetainsEverySegmentInOrder(t *testing.T) {
	segments := []EvidenceSegment{
		{ID: "one", Text: strings.Repeat("a", 300)},
		{ID: "two", Text: strings.Repeat("b", 300)},
		{ID: "three", Text: strings.Repeat("c", 300)},
	}
	batches := splitEvidenceBatches(segments, 600)
	var ids []string
	for _, batch := range batches {
		for _, segment := range batch {
			ids = append(ids, segment.ID)
		}
	}
	if strings.Join(ids, ",") != "one,two,three" {
		t.Fatalf("batch IDs = %v, want every source segment in order", ids)
	}
}

func TestCompleteJSONMessagesFallsBackWhenProviderRejectsJSONMode(t *testing.T) {
	var mu sync.Mutex
	var bodies []string
	service := NewWithModels("test-key", "test/model", "test/model", "")
	service.httpClient = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		mu.Lock()
		bodies = append(bodies, string(body))
		call := len(bodies)
		mu.Unlock()
		if call == 1 {
			return &http.Response{
				StatusCode: http.StatusBadRequest,
				Body:       io.NopCloser(strings.NewReader(`{"error":{"message":"response_format is unsupported"}}`)),
				Header:     make(http.Header),
			}, nil
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Body: io.NopCloser(bytes.NewBufferString(
				`{"model":"provider/model","choices":[{"message":{"content":"{\"answer\":\"ok\"}"}}]}`,
			)),
			Header: make(http.Header),
		}, nil
	})}

	content, model, err := service.completeJSONMessages(context.Background(), "test/model", []chatMessage{
		{Role: "user", Content: "Return JSON"},
	}, mediumSummaryMaxTokens)
	if err != nil {
		t.Fatalf("completeJSONMessages() error = %v", err)
	}
	if content != `{"answer":"ok"}` || model != "provider/model" {
		t.Fatalf("result = (%q, %q), want parsed fallback response", content, model)
	}
	if len(bodies) != 2 {
		t.Fatalf("request count = %d, want 2", len(bodies))
	}
	if !strings.Contains(bodies[0], `"response_format"`) {
		t.Fatalf("first request did not enable JSON mode: %s", bodies[0])
	}
	if strings.Contains(bodies[1], `"response_format"`) {
		t.Fatalf("fallback request still included JSON mode: %s", bodies[1])
	}
	for index, body := range bodies {
		if !strings.Contains(body, `"max_tokens":3000`) {
			t.Fatalf("request %d did not retain the explicit output budget: %s", index+1, body)
		}
	}
}

func TestCompleteJSONMessagesBoundsProviderOutputBudget(t *testing.T) {
	service := NewWithModels("test-key", "test/model", "test/model", "")
	service.httpClient = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		if !strings.Contains(string(body), `"max_tokens":1500`) {
			t.Fatalf("request body = %s, want explicit 1500-token budget", body)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Body: io.NopCloser(bytes.NewBufferString(
				`{"model":"provider/model","choices":[{"message":{"content":"{\"answer\":\"ok\"}"}}]}`,
			)),
			Header: make(http.Header),
		}, nil
	})}

	_, _, err := service.completeJSONMessages(context.Background(), "test/model", []chatMessage{
		{Role: "user", Content: "Return JSON"},
	}, shortSummaryMaxTokens)
	if err != nil {
		t.Fatalf("completeJSONMessages() error = %v", err)
	}
}
