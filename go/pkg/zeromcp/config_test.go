package zeromcp

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfigMissing(t *testing.T) {
	cfg, err := LoadConfig("/nonexistent/path/config.json")
	if err != nil {
		t.Fatalf("expected no error for missing file, got %v", err)
	}
	if cfg.Logging {
		t.Error("expected default config")
	}
}

func TestLoadConfigValid(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	os.WriteFile(path, []byte(`{"logging": true, "separator": "-"}`), 0644)

	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !cfg.Logging {
		t.Error("expected logging=true")
	}
	if cfg.Separator != "-" {
		t.Errorf("expected separator '-', got %q", cfg.Separator)
	}
}

func TestResolveTransportsDefault(t *testing.T) {
	transports := ResolveTransports(Config{})
	if len(transports) != 1 || transports[0].Type != "stdio" {
		t.Error("expected default stdio transport")
	}
}

func TestResolveAuthEnv(t *testing.T) {
	os.Setenv("TEST_ZEROMCP_AUTH", "secret123")
	defer os.Unsetenv("TEST_ZEROMCP_AUTH")

	result := ResolveAuth("env:TEST_ZEROMCP_AUTH")
	if result != "secret123" {
		t.Errorf("expected 'secret123', got %q", result)
	}
}

func TestResolveAuthLiteral(t *testing.T) {
	result := ResolveAuth("my-token")
	if result != "my-token" {
		t.Errorf("expected 'my-token', got %q", result)
	}
}

func TestResolveCredentialsEnv(t *testing.T) {
	os.Setenv("TEST_ZEROMCP_CRED", "api-key-123")
	defer os.Unsetenv("TEST_ZEROMCP_CRED")

	result := ResolveCredentials(CredentialSource{Env: "TEST_ZEROMCP_CRED"})
	if result != "api-key-123" {
		t.Errorf("expected 'api-key-123', got %v", result)
	}
}

func TestResolveCredentialsFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cred.txt")
	os.WriteFile(path, []byte("file-secret"), 0644)

	result := ResolveCredentials(CredentialSource{File: path})
	if result != "file-secret" {
		t.Errorf("expected 'file-secret', got %v", result)
	}
}
