// Timeout conformance test binary.
// Registers a fast tool and a slow tool with execute_timeout to test timeout enforcement.
// Build: go build -o zeromcp-go-timeout ./examples/timeout-test
package main

import (
	"time"

	"github.com/antidrift-dev/zeromcp-go/pkg/zeromcp"
)

func main() {
	s := zeromcp.NewServer()

	s.Tool("hello", zeromcp.Tool{
		Description: "Fast tool",
		Input:       zeromcp.Input{"name": "string"},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			name, _ := args["name"].(string)
			if name == "" {
				name = "world"
			}
			return "Hello, " + name + "!", nil
		},
	})

	s.Tool("slow", zeromcp.Tool{
		Description: "Tool that takes 3 seconds",
		Input:       zeromcp.Input{},
		Permissions: &zeromcp.Permissions{
			ExecuteTimeout: 2000,
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			time.Sleep(3 * time.Second)
			return map[string]any{"status": "ok"}, nil
		},
	})

	s.ServeStdio()
}
