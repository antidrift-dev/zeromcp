// Route test harness: registers a greet tool (GET /greet/:name) and echo tool
// (POST /echo), then mounts s.Registry() on a stdlib http.ServeMux on :14254.
// ZeroMCP has no built-in HTTP server; this is what a user's own server does.
// /docs is served only because tests/conformance/run-route.js checks for it.
// Build: go build -o route-test ./examples/route-test
// Run:   ./route-test
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"

	"github.com/antidrift-dev/zeromcp-go/pkg/zeromcp"
)

const swaggerHTML = `<!DOCTYPE html>
<html>
<head>
  <title>ZeroMCP API</title>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
</head>
<body>
<div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>
</body>
</html>`

var paramRe = regexp.MustCompile(`:(\w+)`)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func main() {
	s := zeromcp.NewServer()

	s.Tool("greet", zeromcp.Tool{
		Description: "Greet a person by name",
		Input:       zeromcp.Input{"name": "string"},
		Route:       &zeromcp.RouteConfig{Method: "GET", Path: "/greet/:name"},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			name, _ := args["name"].(string)
			return fmt.Sprintf("Hello, %s!", name), nil
		},
	})

	s.Tool("echo", zeromcp.Tool{
		Description: "Echo a message back",
		Input:       zeromcp.Input{"message": "string"},
		Route:       &zeromcp.RouteConfig{Method: "POST", Path: "/echo"},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			return map[string]any{
				"message": args["message"],
				"echoed":  true,
			}, nil
		},
	})

	reg := s.Registry()
	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"status": "ok"})
	})
	mux.HandleFunc("GET /openapi.json", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, reg.OpenAPI)
	})
	mux.HandleFunc("GET /docs", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(200)
		io.WriteString(w, swaggerHTML)
	})
	mux.HandleFunc("POST /mcp", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		out := reg.MCP(body)
		if out == nil {
			w.WriteHeader(204)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(out)
	})

	for _, route := range reg.Routes {
		route := route
		var params []string
		path := paramRe.ReplaceAllStringFunc(route.Route.Path, func(m string) string {
			params = append(params, m[1:])
			return "{" + m[1:] + "}"
		})
		method := strings.ToUpper(route.Route.Method)

		mux.HandleFunc(method+" "+path, func(w http.ResponseWriter, r *http.Request) {
			args := map[string]any{}
			for _, p := range params {
				args[p] = r.PathValue(p)
			}
			if method == "GET" {
				for k, vals := range r.URL.Query() {
					if len(vals) > 0 {
						args[k] = vals[0]
					}
				}
			} else {
				body, _ := io.ReadAll(r.Body)
				var m map[string]any
				if len(body) > 0 && json.Unmarshal(body, &m) == nil {
					for k, v := range m {
						args[k] = v
					}
				}
			}

			result, err := route.Invoke(args)
			if err != nil {
				writeJSON(w, 500, map[string]any{"ok": false, "error": err.Error()})
				return
			}
			writeJSON(w, 200, map[string]any{"ok": true, "result": result})
		})
	}

	fmt.Fprintln(os.Stderr, "[route-test] listening on :14254")
	if err := http.ListenAndServe(":14254", mux); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
