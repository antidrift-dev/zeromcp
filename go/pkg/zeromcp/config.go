package zeromcp

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// Config holds the server configuration, loaded from zeromcp.config.json.
type Config struct {
	Transport         any                          `json:"transport,omitempty"`
	Logging           bool                         `json:"logging,omitempty"`
	BypassPermissions bool                         `json:"bypass_permissions,omitempty"`
	Separator         string                       `json:"separator,omitempty"`
	Credentials       map[string]CredentialSource  `json:"credentials,omitempty"`
	CacheCredentials  *bool                        `json:"cache_credentials,omitempty"` // default true
	ExecuteTimeout    int                          `json:"execute_timeout,omitempty"`   // ms, default 30000
	PageSize          int                          `json:"page_size,omitempty"`         // 0 = no pagination
	Icon              string                       `json:"icon,omitempty"`              // data URI, URL, or file path (resolved at startup)
	Title             string                       `json:"title,omitempty"`             // OpenAPI spec title (default "ZeroMCP")
	Remote            []RemoteServer               `json:"remote,omitempty"`            // upstream MCP servers whose tools are federated in
	AutoloadTools     bool                         `json:"autoload_tools,omitempty"`    // watch tool sources and rescan on change (CLI)
	Tools             any                          `json:"tools,omitempty"`             // string | []string | []ToolSource (mixed), like Transport
	Namespacing       map[string]NamespaceOverride `json:"namespacing,omitempty"`       // per top-level dir prefix overrides
	Resources         any                          `json:"resources,omitempty"`         // same shape as Tools; only path is used
	Prompts           any                          `json:"prompts,omitempty"`           // same shape as Tools; only path is used
}

// RemoteServer is an upstream MCP server whose tools are federated in.
type RemoteServer struct {
	Name  string   `json:"name"`
	URL   string   `json:"url"`
	Auth  string   `json:"auth,omitempty"`  // literal or "env:VAR"
	Tools []string `json:"tools,omitempty"` // allowlist of upstream names; nil = all, empty = none
}

// ToolSource is one directory to scan, with an optional name prefix.
type ToolSource struct {
	Path   string `json:"path"`
	Prefix string `json:"prefix,omitempty"`
}

// NamespaceOverride overrides the prefix used for a top-level tool directory.
type NamespaceOverride struct {
	Prefix *string `json:"prefix,omitempty"` // nil = use dir name; "" = no prefix
}

// TransportConfig defines a transport type.
type TransportConfig struct {
	Type string `json:"type"`
}

// CredentialSource specifies where to load credentials from.
type CredentialSource struct {
	Env  string `json:"env,omitempty"`
	File string `json:"file,omitempty"`
}

// LoadConfig reads a zeromcp.config.json file.
func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Config{}, nil
		}
		return Config{}, err
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("invalid config: %w", err)
	}

	// Default cache_credentials to true when not explicitly set in config
	if cfg.CacheCredentials == nil {
		t := true
		cfg.CacheCredentials = &t
	}

	return cfg, nil
}

// ResolveTransports parses the transport field into a list of TransportConfigs.
func ResolveTransports(cfg Config) []TransportConfig {
	if cfg.Transport == nil {
		return []TransportConfig{{Type: "stdio"}}
	}

	// Already parsed by JSON into interface{} — could be object or array
	data, _ := json.Marshal(cfg.Transport)

	// Try single object
	var single TransportConfig
	if err := json.Unmarshal(data, &single); err == nil && single.Type != "" {
		return []TransportConfig{single}
	}

	// Try array
	var arr []TransportConfig
	if err := json.Unmarshal(data, &arr); err == nil {
		return arr
	}

	return []TransportConfig{{Type: "stdio"}}
}

// checkTransports rejects the removed built-in "http" transport.
func checkTransports(cfg Config) error {
	for _, t := range ResolveTransports(cfg) {
		if t.Type == "http" {
			return fmt.Errorf(`[zeromcp] The built-in "http" transport was removed. Mount (*Server).Registry() in your own HTTP server: Routes for tool routes, OpenAPI for /openapi.json, MCP for POST /mcp. Remove the "http" entry from "transport".`)
		}
	}
	return nil
}

// ResolveToolSources normalizes Config.Tools (or Resources/Prompts): a string,
// or an array of strings and {path, prefix} objects. nil → [{Path: "./tools"}].
func ResolveToolSources(tools any) []ToolSource {
	if tools == nil {
		return []ToolSource{{Path: "./tools"}}
	}
	data, err := json.Marshal(tools)
	if err != nil {
		return []ToolSource{{Path: "./tools"}}
	}

	var single string
	if err := json.Unmarshal(data, &single); err == nil {
		if single == "" {
			return []ToolSource{{Path: "./tools"}}
		}
		return []ToolSource{{Path: single}}
	}

	var arr []json.RawMessage
	if err := json.Unmarshal(data, &arr); err != nil {
		return []ToolSource{{Path: "./tools"}}
	}
	sources := make([]ToolSource, 0, len(arr))
	for _, el := range arr {
		var p string
		if err := json.Unmarshal(el, &p); err == nil {
			sources = append(sources, ToolSource{Path: p})
			continue
		}
		var src ToolSource
		if err := json.Unmarshal(el, &src); err == nil {
			sources = append(sources, src)
		}
	}
	return sources
}

// ResolveCredentials reads a credential from the specified source.
func ResolveCredentials(source CredentialSource) any {
	if source.Env != "" {
		value := os.Getenv(source.Env)
		if value == "" {
			fmt.Fprintf(os.Stderr, "[zeromcp] Warning: environment variable %s not set\n", source.Env)
			return nil
		}
		var parsed any
		if err := json.Unmarshal([]byte(value), &parsed); err == nil {
			return parsed
		}
		return value
	}

	if source.File != "" {
		path := source.File
		if strings.HasPrefix(path, "~") {
			home, _ := os.UserHomeDir()
			path = home + path[1:]
		}
		data, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[zeromcp] Warning: cannot read credential file %s\n", path)
			return nil
		}
		var parsed any
		if err := json.Unmarshal(data, &parsed); err == nil {
			return parsed
		}
		return string(data)
	}

	return nil
}
