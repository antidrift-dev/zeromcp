// Basic example: register tools in code, serve over stdio.
// Build: go build -o my-server ./examples/basic
// Run:   ./my-server
package main

import (
	"fmt"
	"time"

	"github.com/probeo-io/zeromcp/pkg/zeromcp"
)

func main() {
	s := zeromcp.NewServer()

	s.Tool("hello", zeromcp.Tool{
		Description: "Say hello to someone",
		Input:       zeromcp.Input{"name": "string"},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			return fmt.Sprintf("Hello, %s!", args["name"]), nil
		},
	})

	s.Tool("add", zeromcp.Tool{
		Description: "Add two numbers together",
		Input: zeromcp.Input{
			"a": "number",
			"b": "number",
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			a, _ := args["a"].(float64)
			b, _ := args["b"].(float64)
			return map[string]any{"sum": a + b}, nil
		},
	})

	s.Tool("create_invoice", zeromcp.Tool{
		Description: "Create an invoice",
		Input: zeromcp.Input{
			"customer_id": "string",
			"amount":      "number",
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			return map[string]any{
				"id":          fmt.Sprintf("inv_%d", time.Now().UnixMilli()),
				"customer_id": args["customer_id"],
				"amount":      args["amount"],
				"status":      "draft",
				"created":     time.Now().Format(time.RFC3339),
			}, nil
		},
	})

	s.ServeStdio()
}
