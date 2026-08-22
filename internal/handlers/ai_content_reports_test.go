package handlers

import (
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestValidateAIContentReport(t *testing.T) {
	t.Parallel()
	valid := models.CreateAIContentReportRequest{
		TargetType: "chat_message",
		TargetID:   uuid.NewString(),
		Category:   "dangerous",
		Details:    "The answer encourages unsafe behavior.",
	}
	if err := validateAIContentReport(valid); err != nil {
		t.Fatalf("valid report rejected: %v", err)
	}

	tests := []struct {
		name   string
		mutate func(*models.CreateAIContentReportRequest)
	}{
		{name: "unknown target", mutate: func(req *models.CreateAIContentReportRequest) { req.TargetType = "prompt" }},
		{name: "invalid id", mutate: func(req *models.CreateAIContentReportRequest) { req.TargetID = "not-a-uuid" }},
		{name: "unknown category", mutate: func(req *models.CreateAIContentReportRequest) { req.Category = "spam" }},
		{name: "details too long", mutate: func(req *models.CreateAIContentReportRequest) { req.Details = strings.Repeat("x", 1001) }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			req := valid
			test.mutate(&req)
			if err := validateAIContentReport(req); err == nil {
				t.Fatal("invalid report accepted")
			}
		})
	}
}
