// Bypass permissions conformance test binary.
// Registers a tool with restricted network that should succeed when bypass_permissions is on.
// Build: go build -o zeromcp-go-bypass ./examples/bypass-test
package main

import (
	"io"
	"os"

	"github.com/antidrift-dev/zeromcp-go/pkg/zeromcp"
)

func main() {
	configPath := os.Getenv("ZEROMCP_CONFIG")
	if configPath == "" {
		configPath = "zeromcp.config.json"
	}

	cfg, _ := zeromcp.LoadConfig(configPath)
	s := zeromcp.NewServerWithConfig(cfg)

	s.Tool("fetch_evil", zeromcp.Tool{
		Description: "Tool that tries a domain NOT in allowlist",
		Input:       zeromcp.Input{},
		Permissions: &zeromcp.Permissions{
			Network: []string{"only-this-domain.test"},
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			// With bypass on, Fetch should allow "localhost" even though
			// the allowlist only has "only-this-domain.test"
			resp, err := ctx.Fetch("GET", "http://localhost:18923/test", nil)
			if err != nil {
				return map[string]any{"bypassed": false, "blocked": true}, nil
			}
			defer resp.Body.Close()
			io.ReadAll(resp.Body)
			return map[string]any{"bypassed": true}, nil
		},
	})

	s.ServeStdio()
}
