// Resource test: registers tools, resources, and prompts for v0.2.0 conformance testing.
// Build: go build -o resource-test ./examples/resource-test
// Run:   ./resource-test
package main

import (
	"fmt"

	"github.com/antidrift-dev/zeromcp/pkg/zeromcp"
)

func main() {
	s := zeromcp.NewServer()

	// Tool: hello
	s.Tool("hello", zeromcp.Tool{
		Description: "Say hello to someone",
		Input:       zeromcp.Input{"name": "string"},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			return fmt.Sprintf("Hello, %s!", args["name"]), nil
		},
	})

	// Static resource: data
	s.Resource("data", zeromcp.ResourceDef{
		URI:         "resource:///data.json",
		Description: "Static JSON data",
		MimeType:    "application/json",
		Read: func() (string, error) {
			return `{"key":"value","count":42}`, nil
		},
	})

	// Static resource: dynamic (fixed content for testing)
	s.Resource("dynamic", zeromcp.ResourceDef{
		URI:         "resource:///dynamic",
		Description: "Dynamic JSON resource",
		MimeType:    "application/json",
		Read: func() (string, error) {
			return `{"dynamic":true,"timestamp":"test"}`, nil
		},
	})

	// Static resource: readme
	s.Resource("readme", zeromcp.ResourceDef{
		URI:         "resource:///readme.md",
		Description: "Test markdown file",
		MimeType:    "text/markdown",
		Read: func() (string, error) {
			return "# Test Resource\nThis is a test markdown file.", nil
		},
	})

	// Prompt: greet
	s.Prompt("greet", zeromcp.PromptDef{
		Description: "Greeting prompt",
		Arguments: []zeromcp.PromptArgument{
			{Name: "name", Required: true},
			{Name: "tone", Description: "formal or casual", Required: false},
		},
		Render: func(args map[string]any) ([]zeromcp.PromptMessage, error) {
			name, _ := args["name"].(string)
			tone, _ := args["tone"].(string)
			if tone == "" {
				tone = "friendly"
			}
			return []zeromcp.PromptMessage{
				{
					Role: "user",
					Content: map[string]any{
						"type": "text",
						"text":  fmt.Sprintf("Greet %s in a %s tone", name, tone),
					},
				},
			}, nil
		},
	})

	s.ServeStdio()
}
