package zeromcp

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
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

func TestCheckTransportsRejectsHTTP(t *testing.T) {
	cases := map[string]any{
		"single object": map[string]any{"type": "http"},
		"in array":      []any{map[string]any{"type": "stdio"}, map[string]any{"type": "http", "port": 4242}},
		"typed":         []TransportConfig{{Type: "http"}},
	}
	for label, transport := range cases {
		err := checkTransports(Config{Transport: transport})
		if err == nil {
			t.Errorf("%s: expected error", label)
			continue
		}
		if !strings.Contains(err.Error(), `The built-in "http" transport was removed`) ||
			!strings.Contains(err.Error(), "(*Server).Registry()") {
			t.Errorf("%s: unexpected message %q", label, err.Error())
		}
	}
}

func TestCheckTransportsAllowsStdio(t *testing.T) {
	if err := checkTransports(Config{}); err != nil {
		t.Errorf("default: unexpected error %v", err)
	}
	if err := checkTransports(Config{Transport: map[string]any{"type": "stdio"}}); err != nil {
		t.Errorf("stdio: unexpected error %v", err)
	}
}

func TestResolveToolSources(t *testing.T) {
	cases := []struct {
		label string
		in    any
		want  []ToolSource
	}{
		{"nil", nil, []ToolSource{{Path: "./tools"}}},
		{"string", "./my-tools", []ToolSource{{Path: "./my-tools"}}},
		{"[]string", []string{"./a", "./b"}, []ToolSource{{Path: "./a"}, {Path: "./b"}}},
		{"mixed", []any{"./a", map[string]any{"path": "./b", "prefix": "ext"}},
			[]ToolSource{{Path: "./a"}, {Path: "./b", Prefix: "ext"}}},
		{"typed", []ToolSource{{Path: "./c", Prefix: "p"}}, []ToolSource{{Path: "./c", Prefix: "p"}}},
	}
	for _, c := range cases {
		got := ResolveToolSources(c.in)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %+v, want %+v", c.label, got, c.want)
		}
	}
}

func TestLoadConfigParsesNewFields(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	os.WriteFile(path, []byte(`{
		"tools": ["./a", {"path": "./b", "prefix": "ext"}],
		"namespacing": {"crm": {"prefix": ""}, "db": {}},
		"autoload_tools": true,
		"resources": "./res",
		"prompts": ["./prompts"],
		"remote": [{"name": "up", "url": "http://x", "auth": "env:T", "tools": []}]
	}`), 0644)

	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !cfg.AutoloadTools {
		t.Error("expected autoload_tools=true")
	}
	if got := ResolveToolSources(cfg.Tools); len(got) != 2 || got[1].Prefix != "ext" {
		t.Errorf("unexpected tools: %+v", got)
	}
	if p := cfg.Namespacing["crm"].Prefix; p == nil || *p != "" {
		t.Errorf("expected crm prefix \"\", got %v", p)
	}
	if p := cfg.Namespacing["db"].Prefix; p != nil {
		t.Errorf("expected db prefix nil, got %q", *p)
	}
	if len(cfg.Remote) != 1 || cfg.Remote[0].Auth != "env:T" || cfg.Remote[0].Tools == nil || len(cfg.Remote[0].Tools) != 0 {
		t.Errorf("unexpected remote: %+v", cfg.Remote)
	}
	if d := sourceDirs(cfg.Resources); len(d) != 1 || d[0] != "./res" {
		t.Errorf("unexpected resources: %v", d)
	}
	if d := sourceDirs(cfg.Prompts); len(d) != 1 || d[0] != "./prompts" {
		t.Errorf("unexpected prompts: %v", d)
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
