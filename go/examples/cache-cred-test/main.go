// Cache credentials conformance test binary.
// Reads credentials via server.ResolveToolCredentials on each call,
// which respects the cache_credentials config flag.
// Build: go build -o zeromcp-go-cache-cred ./examples/cache-cred-test
package main

import (
	"os"

	"github.com/antidrift-dev/zeromcp/pkg/zeromcp"
)

func main() {
	configPath := os.Getenv("ZEROMCP_CONFIG")
	if configPath == "" {
		configPath = "zeromcp.config.json"
	}

	cfg, _ := zeromcp.LoadConfig(configPath)
	s := zeromcp.NewServerWithConfig(cfg)

	// Resolve credentials per-call via server so cache_credentials is respected.
	s.Tool("tokenstore_check", zeromcp.Tool{
		Description: "Return the current token from credentials",
		Input:       zeromcp.Input{},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			creds := s.ResolveToolCredentials("tokenstore")
			var token any
			if m, ok := creds.(map[string]any); ok {
				token = m["token"]
			}
			return map[string]any{"token": token}, nil
		},
	})

	s.ServeStdio()
}
