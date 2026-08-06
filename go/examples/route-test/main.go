// Route test example: registers a greet tool (GET /greet/:name) and echo tool (POST /echo).
// Build: go build -o route-test ./examples/route-test
// Run:   ./route-test
package main

import (
	"fmt"

	"github.com/antidrift-dev/zeromcp/pkg/zeromcp"
)

func main() {
	s := zeromcp.NewServerWithConfig(zeromcp.Config{
		Transport: []zeromcp.TransportConfig{{Type: "http", Port: 14254}},
	})

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

	s.Serve()
}
