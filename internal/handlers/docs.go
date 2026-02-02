// docs.go serves the OpenAPI specification and Swagger UI (MTA-10).
//
// Instead of using swaggo/swag (which requires specific comment annotations
// and a code generation step), we write the OpenAPI 3.0 spec as a YAML file
// and serve it alongside Swagger UI from a CDN. This approach is simpler,
// more portable, and doesn't add build-time dependencies.
//
// Go Pattern: Embedding static files. Go 1.16+ has `embed` which lets you
// include files directly in the binary. For the OpenAPI spec, we embed it
// so the binary is fully self-contained.
package handlers

import (
	_ "embed"
	"net/http"

	"github.com/gin-gonic/gin"
)

// openAPISpec is the OpenAPI 3.0 YAML specification embedded at compile time.
// Go Pattern: The `//go:embed` directive tells the compiler to include
// the file contents in the binary. The variable is populated at build time,
// not runtime — so the file must exist when you run `go build`.
//
//go:embed openapi.yaml
var openAPISpec []byte

// ServeOpenAPISpec returns the raw OpenAPI YAML specification.
// GET /api/docs/openapi.yaml
func (h *Handler) ServeOpenAPISpec(c *gin.Context) {
	c.Data(http.StatusOK, "application/yaml", openAPISpec)
}

// ServeSwaggerUI returns an HTML page that loads Swagger UI from a CDN
// and points it at our OpenAPI spec.
// GET /api/docs
//
// Go Pattern: For simple HTML responses, a raw string is fine.
// For complex templates, use Go's html/template package.
func (h *Handler) ServeSwaggerUI(c *gin.Context) {
	html := `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Media Tools API — Documentation</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">
  <style>
    body { margin: 0; background: #fafafa; }
    .swagger-ui .topbar { display: none; }
    .swagger-ui .info { margin: 20px 0; }
  </style>
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    SwaggerUIBundle({
      url: '/api/docs/openapi.yaml',
      dom_id: '#swagger-ui',
      presets: [
        SwaggerUIBundle.presets.apis,
        SwaggerUIBundle.SwaggerUIStandalonePreset
      ],
      layout: 'BaseLayout',
      deepLinking: true,
      defaultModelsExpandDepth: 2,
      defaultModelExpandDepth: 2,
    });
  </script>
</body>
</html>`

	c.Data(http.StatusOK, "text/html; charset=utf-8", []byte(html))
}
