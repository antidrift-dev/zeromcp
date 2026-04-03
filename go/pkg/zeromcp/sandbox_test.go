package zeromcp

import (
	"testing"
)

func TestIsAllowedExact(t *testing.T) {
	if !isAllowed("api.example.com", []string{"api.example.com"}) {
		t.Error("expected api.example.com to be allowed")
	}
	if isAllowed("evil.com", []string{"api.example.com"}) {
		t.Error("expected evil.com to be denied")
	}
}

func TestIsAllowedWildcard(t *testing.T) {
	allowlist := []string{"*.example.com"}

	if !isAllowed("api.example.com", allowlist) {
		t.Error("expected api.example.com to match *.example.com")
	}
	if !isAllowed("example.com", allowlist) {
		t.Error("expected example.com to match *.example.com (base domain)")
	}
	if isAllowed("evil.com", allowlist) {
		t.Error("expected evil.com to not match *.example.com")
	}
	if isAllowed("notexample.com", allowlist) {
		t.Error("expected notexample.com to not match *.example.com")
	}
}

func TestSandboxFetchDenied(t *testing.T) {
	ctx := NewContext("test_tool", &Permissions{NetworkDisabled: true}, SandboxOptions{}, nil)
	_, err := ctx.Fetch("GET", "https://evil.com/data", nil)
	if err == nil {
		t.Error("expected fetch to be denied")
	}
}

func TestSandboxFetchAllowlistDenied(t *testing.T) {
	ctx := NewContext("test_tool", &Permissions{
		Network: []string{"api.example.com"},
	}, SandboxOptions{}, nil)

	_, err := ctx.Fetch("GET", "https://evil.com/data", nil)
	if err == nil {
		t.Error("expected fetch to evil.com to be denied")
	}
}

func TestSandboxFetchBypass(t *testing.T) {
	ctx := NewContext("test_tool", &Permissions{NetworkDisabled: true}, SandboxOptions{Bypass: true}, nil)
	// This will try to actually fetch, which will fail, but it should not error on permission
	_, err := ctx.Fetch("GET", "http://localhost:99999/nonexistent", nil)
	// Should get a connection error, not a permission error
	if err != nil && err.Error() == "[zeromcp] test_tool: network access denied" {
		t.Error("bypass should have allowed the request")
	}
}

func TestSandboxNoPermissions(t *testing.T) {
	// nil permissions = unrestricted
	ctx := NewContext("test_tool", nil, SandboxOptions{}, nil)
	// Will fail on connection, but should not fail on permission check
	_, err := ctx.Fetch("GET", "http://localhost:99999/nonexistent", nil)
	if err != nil && err.Error() == "[zeromcp] test_tool: network access denied" {
		t.Error("nil permissions should allow all access")
	}
}
