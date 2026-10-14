// Sandbox conformance test binary.
// Registers tools with various permission levels to test sandbox enforcement.
// Build: go build -o zeromcp-go-sandbox ./examples/sandbox-test
package main

import (
	"encoding/json"
	"fmt"
	"io"

	"github.com/antidrift-dev/zeromcp-go/pkg/zeromcp"
)

func main() {
	s := zeromcp.NewServer()

	// Tool with allowed domain
	s.Tool("fetch_allowed", zeromcp.Tool{
		Description: "Fetch an allowed domain",
		Input:       zeromcp.Input{},
		Permissions: &zeromcp.Permissions{
			Network: []string{"localhost"},
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			resp, err := ctx.Fetch("GET", "http://localhost:18923/test", nil)
			if err != nil {
				return map[string]any{"status": "error", "message": err.Error()}, nil
			}
			defer resp.Body.Close()
			io.ReadAll(resp.Body)
			return map[string]any{"status": "ok", "domain": "localhost"}, nil
		},
	})

	// Tool that tries a blocked domain
	s.Tool("fetch_blocked", zeromcp.Tool{
		Description: "Fetch a blocked domain",
		Input:       zeromcp.Input{},
		Permissions: &zeromcp.Permissions{
			Network: []string{"localhost"},
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			_, err := ctx.Fetch("GET", "http://evil.test:18923/steal", nil)
			if err != nil {
				return map[string]any{"blocked": true, "domain": "evil.test"}, nil
			}
			return map[string]any{"blocked": false}, nil
		},
	})

	// Tool with network disabled
	s.Tool("fetch_no_network", zeromcp.Tool{
		Description: "Tool with network disabled",
		Input:       zeromcp.Input{},
		Permissions: &zeromcp.Permissions{
			NetworkDisabled: true,
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			_, err := ctx.Fetch("GET", "http://localhost:18923/test", nil)
			if err != nil {
				return map[string]any{"blocked": true}, nil
			}
			return map[string]any{"blocked": false}, nil
		},
	})

	// Tool with no permissions (unrestricted)
	s.Tool("fetch_unrestricted", zeromcp.Tool{
		Description: "Tool with no network restrictions",
		Input:       zeromcp.Input{},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			resp, err := ctx.Fetch("GET", "http://localhost:18923/test", nil)
			if err != nil {
				return map[string]any{"status": "error", "message": err.Error()}, nil
			}
			defer resp.Body.Close()
			io.ReadAll(resp.Body)
			return map[string]any{"status": "ok", "domain": "localhost"}, nil
		},
	})

	// Tool with wildcard permission
	s.Tool("fetch_wildcard", zeromcp.Tool{
		Description: "Tool with wildcard network permission",
		Input:       zeromcp.Input{},
		Permissions: &zeromcp.Permissions{
			Network: []string{"*.localhost"},
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			resp, err := ctx.Fetch("GET", "http://localhost:18923/test", nil)
			if err != nil {
				return map[string]any{"status": "error", "message": err.Error()}, nil
			}
			defer resp.Body.Close()
			io.ReadAll(resp.Body)
			return map[string]any{"status": "ok", "domain": "localhost"}, nil
		},
	})

	_ = json.Marshal // ensure json import
	_ = fmt.Sprintf  // ensure fmt import

	s.ServeStdio()
}
