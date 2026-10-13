package zeromcp

import (
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func strPtr(s string) *string { return &s }

func TestBuildName(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "src")
	file := func(parts ...string) string { return filepath.Join(append([]string{root}, parts...)...) }

	cases := []struct {
		label  string
		cfg    Config
		path   string
		prefix string
		want   string
	}{
		{"top-level file", Config{}, file("hello.so"), "", "hello"},
		{"default dir prefix", Config{}, file("crm", "list.so"), "", "crm_list"},
		{"nested uses top dir", Config{}, file("crm", "deep", "list.so"), "", "crm_list"},
		{"namespacing override", Config{Namespacing: map[string]NamespaceOverride{"crm": {Prefix: strPtr("x")}}}, file("crm", "list.so"), "", "x_list"},
		{"namespacing empty drops prefix", Config{Namespacing: map[string]NamespaceOverride{"crm": {Prefix: strPtr("")}}}, file("crm", "list.so"), "", "list"},
		{"namespacing nil prefix keeps dir", Config{Namespacing: map[string]NamespaceOverride{"crm": {}}}, file("crm", "list.so"), "", "crm_list"},
		{"source prefix", Config{}, file("crm", "list.so"), "ext", "ext_crm_list"},
		{"source prefix top-level", Config{}, file("hello.so"), "ext", "ext_hello"},
		{"custom separator", Config{Separator: "."}, file("crm", "list.so"), "ext", "ext.crm.list"},
	}
	for _, c := range cases {
		s := NewScanner(root, c.cfg)
		if got := s.buildName(c.path, root, c.prefix); got != c.want {
			t.Errorf("%s: got %q, want %q", c.label, got, c.want)
		}
	}
}

func TestNewScannerFromConfigSources(t *testing.T) {
	s := NewScannerFromConfig(Config{Tools: []any{"./a", map[string]any{"path": "/abs/b", "prefix": "p"}}})
	if len(s.sources) != 2 {
		t.Fatalf("expected 2 sources, got %+v", s.sources)
	}
	if !filepath.IsAbs(s.sources[0].Path) || filepath.Base(s.sources[0].Path) != "a" {
		t.Errorf("expected ./a resolved to an absolute path, got %q", s.sources[0].Path)
	}
	if s.sources[1].Path != "/abs/b" || s.sources[1].Prefix != "p" {
		t.Errorf("unexpected second source %+v", s.sources[1])
	}
}

func TestScanSkipsUnreadableSource(t *testing.T) {
	good := t.TempDir()
	s := NewScannerFromConfig(Config{Tools: []any{filepath.Join(good, "missing"), good}})
	if err := s.Scan(); err != nil {
		t.Errorf("expected nil error when one source is readable, got %v", err)
	}

	s = NewScanner(filepath.Join(good, "missing"), Config{})
	if err := s.Scan(); err == nil {
		t.Error("expected error when no source is readable")
	}
}

func waitFor(t *testing.T, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestWatchFiresOnSoChanges(t *testing.T) {
	dir := t.TempDir()
	s := NewScanner(dir, Config{})
	s.pollInterval = 20 * time.Millisecond

	var calls atomic.Int32
	stop := s.Watch(func() { calls.Add(1) })
	defer stop()

	// Placeholder .so files are not loadable; load errors are only logged.
	so := filepath.Join(dir, "sub", "tool.so")
	os.MkdirAll(filepath.Dir(so), 0755)
	os.WriteFile(so, []byte("not a plugin"), 0644)
	waitFor(t, func() bool { return calls.Load() == 1 }, "onChange after add")

	future := time.Now().Add(time.Hour)
	os.Chtimes(so, future, future)
	waitFor(t, func() bool { return calls.Load() == 2 }, "onChange after touch")

	os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("x"), 0644)
	time.Sleep(150 * time.Millisecond)
	if n := calls.Load(); n != 2 {
		t.Errorf("expected .txt to be ignored, onChange called %d times", n)
	}
}

func TestWatchStopEndsPolling(t *testing.T) {
	dir := t.TempDir()
	s := NewScanner(dir, Config{})
	s.pollInterval = 20 * time.Millisecond

	var calls atomic.Int32
	stop := s.Watch(func() { calls.Add(1) })
	stop()
	stop() // idempotent

	time.Sleep(50 * time.Millisecond)
	os.WriteFile(filepath.Join(dir, "late.so"), []byte("x"), 0644)
	time.Sleep(150 * time.Millisecond)
	if n := calls.Load(); n != 0 {
		t.Errorf("expected no onChange after stop, got %d", n)
	}
}
