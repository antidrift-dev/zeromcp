// Credential injection conformance test binary.
// Loads config, resolves credentials, and registers tools that report credentials.
// Build: go build -o zeromcp-go-creds ./examples/credential-test
package main

import (
	"os"

	"github.com/antidrift-dev/zeromcp-go/pkg/zeromcp"
)

func main() {
	configPath := os.Getenv("ZEROMCP_CONFIG")
	if configPath == "" {
		configPath = "zeromcp.config.json"
	}

	cfg, _ := zeromcp.LoadConfig(configPath)

	// Resolve credentials for "crm" namespace from config
	var crmCreds any
	if src, ok := cfg.Credentials["crm"]; ok {
		crmCreds = zeromcp.ResolveCredentials(src)
	}

	s := zeromcp.NewServerWithConfig(cfg)

	// Capture crmCreds in closure
	s.Tool("crm_check_creds", zeromcp.Tool{
		Description: "Check if credentials were injected",
		Input:       zeromcp.Input{},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			return map[string]any{
				"has_credentials": crmCreds != nil,
				"value":           crmCreds,
			}, nil
		},
	})

	s.Tool("nocreds_check_creds", zeromcp.Tool{
		Description: "Check credentials in unconfigured namespace",
		Input:       zeromcp.Input{},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			return map[string]any{
				"has_credentials": false,
				"value":           nil,
			}, nil
		},
	})

	s.ServeStdio()
}
