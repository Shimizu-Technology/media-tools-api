package summary

import (
	"bytes"
	"context"
	"errors"
	"fmt"
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

	completion, err := service.completeJSONMessages(context.Background(), "test/model", []chatMessage{
		{Role: "user", Content: "Return JSON"},
	}, mediumSummaryMaxTokens)
	if err != nil {
		t.Fatalf("completeJSONMessages() error = %v", err)
	}
	if completion.Content != `{"answer":"ok"}` || completion.Model != "provider/model" {
		t.Fatalf("result = (%q, %q), want parsed fallback response", completion.Content, completion.Model)
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

	_, err := service.completeJSONMessages(context.Background(), "test/model", []chatMessage{
		{Role: "user", Content: "Return JSON"},
	}, shortSummaryMaxTokens)
	if err != nil {
		t.Fatalf("completeJSONMessages() error = %v", err)
	}
}

func TestCompleteCitedSummaryRegeneratesAfterTruncatedLengthResponse(t *testing.T) {
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
			return jsonCompletionResponse(
				`{"summary":{"text":"unfinished","citations":["segment-1"]},"key_points":[`,
				"length",
				3_000,
			), nil
		}
		return jsonCompletionResponse(validCitedSummaryJSON(), "stop", 412), nil
	})}

	segments := []EvidenceSegment{{ID: "segment-1", Text: "Supported evidence"}}
	output, completion, err := service.completeCitedSummary(
		context.Background(),
		"test/model",
		"Return cited JSON.",
		"Summarize the evidence compactly.",
		mediumSummaryMaxTokens,
		segments,
		evidenceSummaryLimits("medium", true),
	)
	if err != nil {
		t.Fatalf("completeCitedSummary() error = %v", err)
	}
	if output.Summary.Text != "Recovered summary" || completion.FinishReason != "stop" {
		t.Fatalf("recovered result = (%q, %q), want valid stop response", output.Summary.Text, completion.FinishReason)
	}
	if len(bodies) != 2 {
		t.Fatalf("request count = %d, want one bounded regeneration", len(bodies))
	}
	if !strings.Contains(bodies[1], "previous response could not be accepted") {
		t.Fatalf("retry request did not include compact regeneration instruction: %s", bodies[1])
	}
	for index, body := range bodies {
		if !strings.Contains(body, `"max_tokens":3000`) {
			t.Fatalf("request %d changed the bounded output budget: %s", index+1, body)
		}
	}
}

func TestCompleteCitedSummaryReturnsTypedErrorAfterTwoInvalidResponses(t *testing.T) {
	calls := 0
	service := NewWithModels("test-key", "test/model", "test/model", "")
	service.httpClient = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		calls++
		return jsonCompletionResponse(`{"summary":`, "length", mediumSummaryMaxTokens), nil
	})}

	_, _, err := service.completeCitedSummary(
		context.Background(),
		"test/model",
		"Return cited JSON.",
		"Summarize.",
		mediumSummaryMaxTokens,
		[]EvidenceSegment{{ID: "segment-1", Text: "Evidence"}},
		evidenceSummaryLimits("medium", true),
	)
	if err == nil {
		t.Fatal("completeCitedSummary() error = nil, want terminal structured output error")
	}
	var structuredErr *StructuredOutputError
	if !errors.As(err, &structuredErr) {
		t.Fatalf("error type = %T, want *StructuredOutputError", err)
	}
	if structuredErr.Attempts != 2 || structuredErr.FinishReason != "length" || calls != 2 {
		t.Fatalf("structured error = %#v after %d calls, want two length attempts", structuredErr, calls)
	}
	if message := PublicErrorMessage(err); !strings.Contains(message, "retried automatically") {
		t.Fatalf("PublicErrorMessage() = %q, want transparent retry guidance", message)
	}
}

func TestCompleteJSONMessagesClassifiesChoiceLevelProviderError(t *testing.T) {
	service := NewWithModels("test-key", "test/model", "test/model", "")
	service.httpClient = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Body: io.NopCloser(strings.NewReader(
				`{"choices":[{"message":{"content":"partial"},"finish_reason":"error","error":{"code":502,"message":"private provider detail","metadata":{"error_type":"provider_unavailable"}}}]}`,
			)),
			Header: make(http.Header),
		}, nil
	})}

	_, err := service.completeJSONMessages(context.Background(), "test/model", []chatMessage{{Role: "user", Content: "Return JSON"}}, 100)
	var providerErr *ProviderError
	if !errors.As(err, &providerErr) {
		t.Fatalf("error type = %T, want *ProviderError", err)
	}
	if providerErr.StatusCode != http.StatusBadGateway || providerErr.ErrorType != "provider_unavailable" {
		t.Fatalf("provider error = %#v, want choice-level 502 classification", providerErr)
	}
	if strings.Contains(err.Error(), "private provider detail") {
		t.Fatalf("error leaked choice-level provider content: %v", err)
	}
}

func TestEvidenceSummaryPromptBoundsUnusedAndVisibleCategories(t *testing.T) {
	audioPrompt := evidenceSummaryPrompt(
		[]EvidenceSegment{{ID: "segment-1", Text: "Evidence"}},
		Options{Length: "medium", Style: "bullet"},
		true,
	)
	for _, expected := range []string{
		"summary: at most 220 words",
		"key_points: at most 7 items",
		"topics: at most 0 items",
	} {
		if !strings.Contains(audioPrompt, expected) {
			t.Fatalf("audio prompt missing %q: %s", expected, audioPrompt)
		}
	}
}

func TestCompleteCitedSummaryRegeneratesValidJSONMarkedAsLength(t *testing.T) {
	calls := 0
	service := NewWithModels("test-key", "test/model", "test/model", "")
	service.httpClient = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		calls++
		finishReason := "length"
		if calls == 2 {
			finishReason = "stop"
		}
		return jsonCompletionResponse(validCitedSummaryJSON(), finishReason, 400), nil
	})}

	output, completion, err := service.completeCitedSummary(
		context.Background(),
		"test/model",
		"Return cited JSON.",
		"Summarize.",
		mediumSummaryMaxTokens,
		[]EvidenceSegment{{ID: "segment-1", Text: "Evidence"}},
		evidenceSummaryLimits("medium", true),
	)
	if err != nil {
		t.Fatalf("completeCitedSummary() error = %v", err)
	}
	if calls != 2 || completion.FinishReason != "stop" || output.Summary.Text != "Recovered summary" {
		t.Fatalf("result = (%d calls, %q, %q), want regeneration followed by a complete response", calls, completion.FinishReason, output.Summary.Text)
	}
}

func TestEnforceEvidenceLimitsCapsOnlyWholeItems(t *testing.T) {
	output := citedOutput{
		Summary: citedClaim{Text: "complete summary remains intact", Citations: []string{"segment-1"}},
		KeyPoints: []citedClaim{
			{Text: "complete first point", Citations: []string{"segment-1"}},
			{Text: "second point", Citations: []string{"segment-1"}},
		},
		ActionItems: []citedClaim{{Text: "complete action item", Citations: []string{"segment-1"}}},
		Decisions:   []citedClaim{{Text: "must be cleared", Citations: []string{"segment-1"}}},
		Topics:      []citedClaim{{Text: "must be cleared", Citations: []string{"segment-1"}}},
	}
	limits := evidenceLimits{SummaryWords: 10, KeyPoints: 1, ActionItems: 1, Decisions: 1, Topics: 0, ClaimWords: 10}

	got := enforceEvidenceLimits(output, limits)
	if got.Summary.Text != "complete summary remains intact" {
		t.Fatalf("summary = %q, want complete text preserved", got.Summary.Text)
	}
	if len(got.KeyPoints) != 1 || got.KeyPoints[0].Text != "complete first point" {
		t.Fatalf("key points = %#v, want one complete item", got.KeyPoints)
	}
	if len(got.ActionItems) != 1 || got.ActionItems[0].Text != "complete action item" {
		t.Fatalf("action items = %#v, want complete claim", got.ActionItems)
	}
	if len(got.Decisions) != 1 || len(got.Topics) != 0 {
		t.Fatalf("zero-category enforcement failed: decisions=%#v topics=%#v", got.Decisions, got.Topics)
	}
}

func TestValidateEvidenceWordLimitsRejectsInsteadOfTruncatingClaims(t *testing.T) {
	output := citedOutput{
		Summary: citedClaim{Text: "complete summary text", Citations: []string{"segment-1"}},
		KeyPoints: []citedClaim{
			{Text: "this claim exceeds the configured limit", Citations: []string{"segment-1"}},
		},
	}
	limits := evidenceLimits{SummaryWords: 10, ClaimWords: 3}

	err := validateEvidenceWordLimits(output, limits)
	if err == nil || !strings.Contains(err.Error(), "key_points item 1") {
		t.Fatalf("validateEvidenceWordLimits() error = %v, want oversized complete claim rejected", err)
	}
	if output.KeyPoints[0].Text != "this claim exceeds the configured limit" {
		t.Fatalf("validation mutated claim text: %q", output.KeyPoints[0].Text)
	}
}

func jsonCompletionResponse(content, finishReason string, completionTokens int) *http.Response {
	payload := fmt.Sprintf(
		`{"model":"provider/model","choices":[{"message":{"content":%q},"finish_reason":%q,"native_finish_reason":%q}],"usage":{"prompt_tokens":1200,"completion_tokens":%d,"total_tokens":%d}}`,
		content,
		finishReason,
		finishReason,
		completionTokens,
		completionTokens+1_200,
	)
	return &http.Response{
		StatusCode: http.StatusOK,
		Body:       io.NopCloser(strings.NewReader(payload)),
		Header:     make(http.Header),
	}
}

func validCitedSummaryJSON() string {
	return `{"summary":{"text":"Recovered summary","citations":["segment-1"]},"key_points":[{"text":"Supported point","citations":["segment-1"]}],"action_items":[],"decisions":[],"topics":[]}`
}
