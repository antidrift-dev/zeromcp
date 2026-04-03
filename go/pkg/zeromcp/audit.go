package zeromcp

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// AuditViolation represents a static analysis warning in a tool file.
type AuditViolation struct {
	File    string `json:"file"`
	Line    int    `json:"line"`
	Pattern string `json:"pattern"`
	Message string `json:"message"`
}

type auditPattern struct {
	regex   *regexp.Regexp
	pattern string
	message string
}

var forbiddenPatterns = []auditPattern{
	{
		regex:   regexp.MustCompile(`http\.Get\s*\(`),
		pattern: "http.Get(",
		message: "Use ctx.Fetch instead of http.Get",
	},
	{
		regex:   regexp.MustCompile(`http\.Post\s*\(`),
		pattern: "http.Post(",
		message: "Use ctx.Fetch instead of http.Post",
	},
	{
		regex:   regexp.MustCompile(`http\.DefaultClient`),
		pattern: "http.DefaultClient",
		message: "Use ctx.Fetch instead of http.DefaultClient",
	},
	{
		regex:   regexp.MustCompile(`os\.ReadFile\s*\(`),
		pattern: "os.ReadFile(",
		message: "Filesystem access should go through the sandbox",
	},
	{
		regex:   regexp.MustCompile(`os\.WriteFile\s*\(`),
		pattern: "os.WriteFile(",
		message: "Filesystem access should go through the sandbox",
	},
	{
		regex:   regexp.MustCompile(`exec\.Command\s*\(`),
		pattern: "exec.Command(",
		message: "Exec access requires exec permission",
	},
	{
		regex:   regexp.MustCompile(`os\.Getenv\s*\(`),
		pattern: "os.Getenv(",
		message: "Use ctx.Credentials for secrets -- not os.Getenv directly",
	},
}

// AuditDir scans Go files in a directory for sandbox violations.
func AuditDir(dir string) ([]AuditViolation, error) {
	var violations []AuditViolation

	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() || filepath.Ext(path) != ".go" {
			return nil
		}
		rel, _ := filepath.Rel(dir, path)
		fileViolations, err := auditFile(rel, path)
		if err != nil {
			return nil
		}
		violations = append(violations, fileViolations...)
		return nil
	})

	return violations, err
}

func auditFile(relPath, fullPath string) ([]AuditViolation, error) {
	f, err := os.Open(fullPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var violations []AuditViolation
	scanner := bufio.NewScanner(f)
	lineNum := 0

	for scanner.Scan() {
		lineNum++
		line := scanner.Text()
		for _, p := range forbiddenPatterns {
			if p.regex.MatchString(line) {
				violations = append(violations, AuditViolation{
					File:    relPath,
					Line:    lineNum,
					Pattern: p.pattern,
					Message: p.message,
				})
			}
		}
	}

	return violations, scanner.Err()
}

// FormatAuditResults formats violations for display.
func FormatAuditResults(violations []AuditViolation) string {
	if len(violations) == 0 {
		return "[zeromcp] Audit passed -- all tools use ctx for sandboxed access"
	}

	var b strings.Builder
	fmt.Fprintf(&b, "[zeromcp] Audit found %d violation(s):\n\n", len(violations))
	for _, v := range violations {
		fmt.Fprintf(&b, "  x %s:%d -- %s\n", v.File, v.Line, v.Pattern)
		fmt.Fprintf(&b, "    %s\n\n", v.Message)
	}
	return b.String()
}
