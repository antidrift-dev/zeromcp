package zeromcp

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAuditCleanFile(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "clean.go"), []byte(`package tools

func run() string {
	return "hello"
}
`), 0644)

	violations, err := AuditDir(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(violations) != 0 {
		t.Errorf("expected 0 violations, got %d", len(violations))
	}
}

func TestAuditViolations(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "bad.go"), []byte(`package tools

import "net/http"
import "os"

func run() {
	http.Get("https://example.com")
	os.Getenv("SECRET")
}
`), 0644)

	violations, err := AuditDir(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(violations) != 2 {
		t.Errorf("expected 2 violations, got %d", len(violations))
	}
}

func TestFormatAuditResultsClean(t *testing.T) {
	result := FormatAuditResults(nil)
	if !strings.Contains(result, "Audit passed") {
		t.Error("expected 'Audit passed' message")
	}
}

func TestFormatAuditResultsViolations(t *testing.T) {
	violations := []AuditViolation{
		{File: "test.go", Line: 5, Pattern: "http.Get(", Message: "Use ctx.Fetch"},
	}
	result := FormatAuditResults(violations)
	if !strings.Contains(result, "1 violation") {
		t.Error("expected '1 violation' in output")
	}
}
