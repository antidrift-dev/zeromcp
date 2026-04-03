// Advanced example: config, permissions, HTTP transport, extended schemas.
// Build: go build -o my-server ./examples/advanced
// Run:   ./my-server
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/probeo-io/zeromcp/pkg/zeromcp"
)

func main() {
	cfg, _ := zeromcp.LoadConfig("zeromcp.config.json")
	s := zeromcp.NewServerWithConfig(cfg)

	// Tool with network permissions and extended input schema
	s.Tool("weather", zeromcp.Tool{
		Description: "Get current weather for a city",
		Input: zeromcp.Input{
			"city": zeromcp.InputField{
				Type:        "string",
				Description: "City name, e.g. 'London'",
			},
			"units": zeromcp.InputField{
				Type:        "string",
				Description: "Temperature units: celsius or fahrenheit",
				Optional:    true,
			},
		},
		Permissions: &zeromcp.Permissions{
			Network: []string{"api.weatherapi.com"},
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			city, _ := args["city"].(string)
			units := "celsius"
			if u, ok := args["units"].(string); ok {
				units = u
			}

			// Use sandboxed fetch -- only api.weatherapi.com is allowed
			resp, err := ctx.Fetch("GET",
				fmt.Sprintf("https://api.weatherapi.com/v1/current.json?q=%s", city),
				nil)
			if err != nil {
				return nil, err
			}
			defer resp.Body.Close()
			body, _ := io.ReadAll(resp.Body)

			var data map[string]any
			json.Unmarshal(body, &data)

			return map[string]any{
				"city":  city,
				"units": units,
				"data":  data,
			}, nil
		},
	})

	// Tool with no network access
	s.Tool("reverse", zeromcp.Tool{
		Description: "Reverse a string",
		Input:       zeromcp.Input{"text": "string"},
		Permissions: &zeromcp.Permissions{
			NetworkDisabled: true,
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			text, _ := args["text"].(string)
			runes := []rune(text)
			for i, j := 0, len(runes)-1; i < j; i, j = i+1, j-1 {
				runes[i], runes[j] = runes[j], runes[i]
			}
			return string(runes), nil
		},
	})

	// Tool that uses credentials from config
	s.Tool("search_contacts", zeromcp.Tool{
		Description: "Search contacts in a CRM",
		Input: zeromcp.Input{
			"query": zeromcp.InputField{
				Type:        "string",
				Description: "Search query",
			},
			"limit": zeromcp.InputField{
				Type:        "number",
				Description: "Max results to return",
				Optional:    true,
			},
		},
		Permissions: &zeromcp.Permissions{
			Network: []string{"*.attio.com"},
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			query, _ := args["query"].(string)
			// In a real implementation, use ctx.Credentials and ctx.Fetch
			return map[string]any{
				"query":   query,
				"results": []string{},
				"message": fmt.Sprintf("Would search for %q using credentials: %v",
					query, ctx.Credentials),
			}, nil
		},
	})

	// Tool returning multi-line formatted output
	s.Tool("format_table", zeromcp.Tool{
		Description: "Format data as a text table",
		Input: zeromcp.Input{
			"headers": "array",
			"rows":    "array",
		},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			headers, _ := args["headers"].([]any)
			rows, _ := args["rows"].([]any)

			var b strings.Builder
			for _, h := range headers {
				fmt.Fprintf(&b, "%-20s", h)
			}
			b.WriteString("\n")
			b.WriteString(strings.Repeat("-", 20*len(headers)))
			b.WriteString("\n")
			for _, row := range rows {
				if cols, ok := row.([]any); ok {
					for _, col := range cols {
						fmt.Fprintf(&b, "%-20v", col)
					}
					b.WriteString("\n")
				}
			}
			return b.String(), nil
		},
	})

	s.Serve()
}
