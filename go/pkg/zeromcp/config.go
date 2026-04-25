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
	Credentials       map[string]CredentialSource   `json:"credentials,omitempty"`
	CacheCredentials  *bool                        `json:"cache_credentials,omitempty"` // default true
	ExecuteTimeout    int                          `json:"execute_timeout,omitempty"` // ms, default 30000
	PageSize          int                          `json:"page_size,omitempty"`       // 0 = no pagination
	Icon              string                       `json:"icon,omitempty"`            // data URI, URL, or file path (resolved at startup)
}

// TransportConfig defines a transport type and its settings.
type TransportConfig struct {
	Type string `json:"type"`
	Port int    `json:"port,omitempty"`
	Auth string `json:"auth,omitempty"`
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

// ResolveAuth resolves an auth token from a string like "env:VAR_NAME" or a literal.
func ResolveAuth(auth string) string {
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
