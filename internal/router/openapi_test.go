package router

import (
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// This catches the easy-to-miss failure mode where a route ships but the
// hand-authored developer spec is never updated.
func TestEveryAPIRouteIsDocumented(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := Setup(RouterConfig{})
	specBytes, err := os.ReadFile("../handlers/openapi.yaml")
	if err != nil {
		t.Fatal(err)
	}
	spec := string(specBytes)

	for _, route := range r.Routes() {
		if !strings.HasPrefix(route.Path, "/api/v1/") {
			continue
		}
		path := strings.TrimPrefix(route.Path, "/api/v1")
		parts := strings.Split(path, "/")
		for i, part := range parts {
			if strings.HasPrefix(part, ":") {
				parts[i] = "{" + strings.TrimPrefix(part, ":") + "}"
			}
		}
		path = strings.Join(parts, "/")
		marker := "\n  " + path + ":\n"
		start := strings.Index(spec, marker)
		if start < 0 {
			t.Errorf("%s %s is missing from OpenAPI", route.Method, path)
			continue
		}
		block := spec[start+len(marker):]
		if end := strings.Index(block, "\n  /"); end >= 0 {
			block = block[:end]
		}
		if !strings.Contains(block, "    "+strings.ToLower(route.Method)+":") {
			t.Errorf("%s %s operation is missing from OpenAPI", route.Method, path)
		}
	}
}

func TestAudioDetailSchemaCoversResponseFields(t *testing.T) {
	data, err := os.ReadFile("../handlers/openapi.yaml")
	if err != nil {
		t.Fatal(err)
	}
	spec := string(data)
	start := strings.Index(spec, "    AudioTranscription:\n")
	end := strings.Index(spec[start:], "    BackfillProgress:")
	if start < 0 || end < 0 {
		t.Fatal("audio schema missing")
	}
	block := spec[start : start+end]
	typ := reflect.TypeOf(models.AudioTranscription{})
	for i := 0; i < typ.NumField(); i++ {
		name := strings.Split(typ.Field(i).Tag.Get("json"), ",")[0]
		if name != "-" && !strings.Contains(block, "\n        "+name+":") {
			t.Errorf("audio response field %s missing from schema", name)
		}
	}
}
