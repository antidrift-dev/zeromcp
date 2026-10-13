package zeromcp

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// remoteTool is one upstream tool, namespaced as <server>.<tool>.
type remoteTool struct {
	name string
	tool Tool
}

// connectRemotes connects to each server in order. A server that fails is
// logged and skipped; the others continue.
func connectRemotes(servers []RemoteServer) []remoteTool {
	var all []remoteTool
	for _, srv := range servers {
		tools, err := connectRemote(srv)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[mcp] Failed to connect to %s: %s\n", srv.Name, err.Error())
			continue
		}
		for _, rt := range tools {
			all = append(all, rt)
			fmt.Fprintf(os.Stderr, "[mcp] Remote tool: %s\n", rt.name)
		}
	}
	return all
}

func connectRemote(srv RemoteServer) (tools []remoteTool, err error) {
	if !strings.HasPrefix(srv.URL, "http://") && !strings.HasPrefix(srv.URL, "https://") {
		return nil, fmt.Errorf("Remote server %q must have an HTTP/HTTPS URL, got: %s", srv.Name, srv.URL)
	}
	auth := resolveAuth(srv.Auth)

	// Initialize (result ignored, as in Node)
	if _, err := httpRPC(srv.URL, map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": map[string]any{},
	}, auth); err != nil {
		return nil, err
	}

	listRes, err := httpRPC(srv.URL, map[string]any{
		"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": map[string]any{},
	}, auth)
	if err != nil {
		return nil, err
	}

	var upstream []any
	if result, ok := listRes["result"].(map[string]any); ok {
		upstream, _ = result["tools"].([]any)
	}

	// ToJsonSchema panics on an unknown type; Node's toJsonSchema throws, failing the whole server.
	defer func() {
		if r := recover(); r != nil {
			tools = nil
			err = fmt.Errorf("%v", r)
		}
	}()

	for _, item := range upstream {
		def, _ := item.(map[string]any)
		if def == nil {
			continue
		}
		upstreamName, _ := def["name"].(string)
		if srv.Tools != nil && !containsString(srv.Tools, upstreamName) {
			continue
		}
		description, _ := def["description"].(string)
		schema, _ := def["inputSchema"].(map[string]any)
		input := schemaToInput(schema)
		ToJsonSchema(input) // surface unknown types now, not at registration

		url := srv.URL
		tools = append(tools, remoteTool{
			name: srv.Name + "." + upstreamName,
			tool: Tool{
				Description: description,
				Input:       input,
				Execute: func(args map[string]any, _ *Ctx) (any, error) {
					callRes, err := httpRPC(url, map[string]any{
						"jsonrpc": "2.0",
						"id":      time.Now().UnixMilli(),
						"method":  "tools/call",
						"params":  map[string]any{"name": upstreamName, "arguments": args},
					}, auth)
					if err != nil {
						return nil, err
					}
					result, ok := callRes["result"]
					if !ok {
						return nil, nil
					}
					if rm, ok := result.(map[string]any); ok {
						if content, ok := rm["content"].([]any); ok && len(content) > 0 {
							if first, ok := content[0].(map[string]any); ok {
								if text, ok := first["text"].(string); ok && text != "" {
									return text, nil
								}
							}
						}
					}
					return result, nil
				},
			},
		})
	}

	fmt.Fprintf(os.Stderr, "[mcp] Connected to %s (HTTP): %d tool(s)\n", srv.Name, len(tools))
	return tools, nil
}

// httpRPC POSTs a JSON-RPC body and decodes the JSON response.
func httpRPC(url string, body any, auth string) (map[string]any, error) {
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest("POST", url, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if auth != "" {
		req.Header.Set("Authorization", "Bearer "+auth)
	}

	// No timeout, as Node's fetch has none.
	resp, err := (&http.Client{}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// schemaToInput converts an upstream JSON Schema back into ZeroMCP's Input shorthand.
func schemaToInput(schema map[string]any) Input {
	input := Input{}
	if schema == nil {
		return input
	}
	props, _ := schema["properties"].(map[string]any)
	if props == nil {
		return input
	}

	required := map[string]bool{}
	switch req := schema["required"].(type) {
	case []any:
		for _, r := range req {
			if s, ok := r.(string); ok {
				required[s] = true
			}
		}
	case []string:
		for _, s := range req {
			required[s] = true
		}
	}

	for key, raw := range props {
		p, _ := raw.(map[string]any)
		typ, _ := p["type"].(string)
		if typ == "" {
			typ = "string"
		}
		desc, _ := p["description"].(string)
		isRequired := required[key]

		if desc != "" || !isRequired {
			input[key] = InputField{Type: typ, Description: desc, Optional: !isRequired}
		} else {
			input[key] = typ
		}
	}
	return input
}

// resolveAuth resolves an auth token from "env:VAR_NAME" or a literal.
func resolveAuth(auth string) string {
	if auth == "" {
		return ""
	}
	if strings.HasPrefix(auth, "env:") {
		envVar := auth[4:]
		value := os.Getenv(envVar)
		if value == "" {
			fmt.Fprintf(os.Stderr, "[zeromcp] Warning: environment variable %s not set\n", envVar)
		}
		return value
	}
	return auth
}

func containsString(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
