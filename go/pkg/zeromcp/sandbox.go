package zeromcp

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
)

// Permissions declares what a tool is allowed to access.
type Permissions struct {
	// Network is a list of allowed hostnames, or nil for unrestricted.
	// Use []string{"api.example.com"} to restrict, or empty slice to deny all.
	Network []string

	// NetworkDisabled explicitly blocks all network access when true.
	NetworkDisabled bool

	// FS controls filesystem access: "read", "write", or empty for none.
	FS string

	// Exec allows spawning child processes.
	Exec bool
}

// SandboxOptions configures sandbox behavior.
type SandboxOptions struct {
	Logging bool
	Bypass  bool
}

// Ctx is the sandboxed context passed to tool execute functions.
type Ctx struct {
	Credentials any
	httpClient  *http.Client
	toolName    string
	permissions *Permissions
	opts        SandboxOptions
}

// Fetch performs an HTTP request, enforcing the tool's network permissions.
func (c *Ctx) Fetch(method, rawURL string, body io.Reader) (*http.Response, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("invalid URL: %w", err)
	}
	hostname := parsed.Hostname()

	if c.permissions != nil {
		if c.permissions.NetworkDisabled {
			if c.opts.Bypass {
				c.log("! %s -> %s %s (network disabled -- bypassed)", c.toolName, method, hostname)
			} else {
				c.log("%s x %s %s (network disabled)", c.toolName, method, hostname)
				return nil, fmt.Errorf("[zeromcp] %s: network access denied", c.toolName)
			}
		} else if c.permissions.Network != nil {
			if !isAllowed(hostname, c.permissions.Network) {
				if c.opts.Bypass {
					c.log("! %s -> %s %s (not in allowlist -- bypassed)", c.toolName, method, hostname)
				} else {
					c.log("%s x %s %s (not in allowlist)", c.toolName, method, hostname)
					return nil, fmt.Errorf("[zeromcp] %s: network access denied for %s (allowed: %s)",
						c.toolName, hostname, strings.Join(c.permissions.Network, ", "))
				}
			}
		}
	}

	c.log("%s -> %s %s", c.toolName, method, hostname)

	req, err := http.NewRequest(method, rawURL, body)
	if err != nil {
		return nil, err
	}
	return c.httpClient.Do(req)
}

func (c *Ctx) log(format string, args ...any) {
	if c.opts.Logging {
		fmt.Fprintf(os.Stderr, "[zeromcp] "+format+"\n", args...)
	}
}

func isAllowed(hostname string, allowlist []string) bool {
	for _, pattern := range allowlist {
		if strings.HasPrefix(pattern, "*.") {
			suffix := pattern[1:] // e.g. ".example.com"
			base := pattern[2:]   // e.g. "example.com"
			if strings.HasSuffix(hostname, suffix) || hostname == base {
				return true
			}
		} else if hostname == pattern {
			return true
		}
	}
	return false
}

// ValidatePermissions logs elevated permission requests to stderr.
func ValidatePermissions(name string, perms *Permissions) {
	if perms == nil {
		return
	}

	var elevated []string
	if perms.FS != "" {
		elevated = append(elevated, fmt.Sprintf("fs: %s", perms.FS))
	}
	if perms.Exec {
		elevated = append(elevated, "exec")
	}

	if len(elevated) > 0 {
		fmt.Fprintf(os.Stderr, "[zeromcp] %s requests elevated permissions: %s\n",
			name, strings.Join(elevated, " | "))
	}
}

// NewContext creates a sandboxed context for a tool.
func NewContext(name string, perms *Permissions, opts SandboxOptions, credentials any) *Ctx {
	return &Ctx{
		Credentials: credentials,
		httpClient:  &http.Client{},
		toolName:    name,
		permissions: perms,
		opts:        opts,
	}
}
