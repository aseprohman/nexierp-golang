// Package docs — Swagger untuk backend Go: menggabungkan kontrak
// api/openapi/{auth,system,inventory}.yaml (sumber kebenaran kontrak kawat
// per modul) menjadi SATU dokumen OpenAPI, lalu melayani:
//
//	GET /api/docs-json  → dokumen gabungan (JSON)
//	GET /api/docs       → Swagger UI (CDN unpkg — butuh internet di dev)
//
// Paritas NestJS: SwaggerModule.setup("api/docs") — publik tanpa guard.
package docs

import (
	"net/http"
	"os"
	"path/filepath"
	"sort"

	"github.com/labstack/echo/v4"
	"gopkg.in/yaml.v3"
)

// Register — pasang /docs-json + /docs pada group (prefix /api dari wiring).
// openapiDir = folder berisi file *.yaml kontrak (repo root/api/openapi).
func Register(g *echo.Group, openapiDir string) {
	g.GET("/docs-json", func(c echo.Context) error {
		doc, err := merge(openapiDir)
		if err != nil {
			return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		return c.JSON(http.StatusOK, doc)
	})
	g.GET("/docs", func(c echo.Context) error {
		html := `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<title>NexiERP API (Go) — Swagger</title>
<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"/>
</head>
<body>
<div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
<script>
window.onload = () => SwaggerUIBundle({
  url: "/api/docs-json",
  dom_id: "#swagger-ui",
  withCredentials: true,
});
</script>
</body>
</html>`
		return c.Blob(http.StatusOK, "text/html; charset=utf-8", []byte(html))
	})
}

// merge — baca semua *.yaml di openapiDir → satu map OpenAPI gabungan:
// paths & components.schemas & tags di-union; info di-sintesis (per modul
// tetap terbaca lewat tag tiap operation). File diurut nama agar stabil.
func merge(dir string) (map[string]any, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && filepath.Ext(e.Name()) == ".yaml" {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)

	out := map[string]any{
		"openapi": "3.1.0",
		"info": map[string]any{
			"title":       "NexiERP API (Go)",
			"description": "Backend Go nexierp-golang — gabungan kontrak per modul (auth, system, inventory). Gateway menyisipkan prefix global /api; servers di bawah adalah origin backend langsung.",
			"version":     "0.1",
		},
		"servers": []any{
			map[string]any{"url": "http://localhost:3101", "description": "Go API (dev)"},
		},
		"paths":      map[string]any{},
		"components": map[string]any{"schemas": map[string]any{}, "securitySchemes": map[string]any{}},
		"tags":       []any{},
		"security":   []any{map[string]any{}},
	}

	secSchemes := out["components"].(map[string]any)["securitySchemes"].(map[string]any)
	paths := out["paths"].(map[string]any)
	comp := out["components"].(map[string]any)["schemas"].(map[string]any)
	tagSet := map[string]bool{}

	for _, f := range files {
		raw, err := os.ReadFile(filepath.Join(dir, f))
		if err != nil {
			return nil, err
		}
		var doc map[string]any
		if err := yaml.Unmarshal(raw, &doc); err != nil {
			return nil, err
		}
		if info, ok := doc["info"].(map[string]any); ok {
			out["info"].(map[string]any)["description"] =
				out["info"].(map[string]any)["description"].(string) +
					"\n\n## " + strOr(info["title"], f) + "\n" + strOr(info["description"], "")
		}
		if p, ok := doc["paths"].(map[string]any); ok {
			for k, v := range p {
				paths[k] = v
			}
		}
		if comps, ok := doc["components"].(map[string]any); ok {
			if sc, ok := comps["schemas"].(map[string]any); ok {
				for k, v := range sc {
					comp[k] = v
				}
			}
			if ss, ok := comps["securitySchemes"].(map[string]any); ok {
				for k, v := range ss {
					secSchemes[k] = v
				}
			}
		}
		if tags, ok := doc["tags"].([]any); ok {
			for _, t := range tags {
				if tm, ok := t.(map[string]any); ok {
					if name, ok := tm["name"].(string); ok && !tagSet[name] {
						tagSet[name] = true
						tm2 := map[string]any{"name": name}
						if d, ok := tm["description"].(string); ok {
							tm2["description"] = d
						}
						out["tags"] = append(out["tags"].([]any), tm2)
					}
				}
			}
		}
		if sec, ok := doc["security"].([]any); ok && len(sec) > 0 {
			out["security"] = sec
		}
	}
	sort.Slice(out["tags"].([]any), func(i, j int) bool {
		a := out["tags"].([]any)[i].(map[string]any)["name"].(string)
		b := out["tags"].([]any)[j].(map[string]any)["name"].(string)
		return a < b
	})
	return out, nil
}

func strOr(v any, def string) string {
	if s, ok := v.(string); ok && s != "" {
		return s
	}
	return def
}
