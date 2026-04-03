package zeromcp

import (
	"fmt"
	"os"
	"path/filepath"
	"plugin"
	"strings"
)

// PluginTool is the interface that Go plugin files must export.
// Plugin .so files must have a variable named "Tool" of this type.
type PluginTool struct {
	Description string
	Input       Input
	Permissions *Permissions
	Execute     func(args map[string]any, ctx *Ctx) (any, error)
}

// Scanner finds and loads tool plugins from a directory.
type Scanner struct {
	Tools     map[string]Tool
	dir       string
	separator string
	cfg       Config
}

// NewScanner creates a scanner for the given tools directory.
func NewScanner(dir string, cfg Config) *Scanner {
	sep := cfg.Separator
	if sep == "" {
		sep = "_"
	}
	return &Scanner{
		Tools:     make(map[string]Tool),
		dir:       dir,
		separator: sep,
		cfg:       cfg,
	}
}

// Scan walks the directory tree looking for .so plugin files.
// Each plugin must export a "Tool" symbol of type *PluginTool.
func (s *Scanner) Scan() error {
	s.Tools = make(map[string]Tool)
	return s.scanDir(s.dir, s.dir)
}

func (s *Scanner) scanDir(dir, rootDir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] Cannot read tools directory: %s\n", dir)
		return err
	}

	for _, entry := range entries {
		fullPath := filepath.Join(dir, entry.Name())

		if entry.IsDir() {
			s.scanDir(fullPath, rootDir)
			continue
		}

		if !entry.Type().IsRegular() {
			continue
		}
		if filepath.Ext(entry.Name()) != ".so" {
			continue
		}

		s.loadPlugin(fullPath, rootDir)
	}

	return nil
}

func (s *Scanner) buildName(filePath, rootDir string) string {
	rel, _ := filepath.Rel(rootDir, filePath)
	parts := strings.Split(rel, string(filepath.Separator))
	filename := parts[len(parts)-1]
	name := strings.TrimSuffix(filename, filepath.Ext(filename))

	if len(parts) > 1 {
		dirName := parts[0]
		name = dirName + s.separator + name
	}

	return name
}

func (s *Scanner) loadPlugin(path, rootDir string) {
	p, err := plugin.Open(path)
	if err != nil {
		rel, _ := filepath.Rel(rootDir, path)
		fmt.Fprintf(os.Stderr, "[zeromcp] Error loading %s: %v\n", rel, err)
		return
	}

	sym, err := p.Lookup("Tool")
	if err != nil {
		rel, _ := filepath.Rel(rootDir, path)
		fmt.Fprintf(os.Stderr, "[zeromcp] %s: no Tool symbol found\n", rel)
		return
	}

	pt, ok := sym.(*PluginTool)
	if !ok {
		rel, _ := filepath.Rel(rootDir, path)
		fmt.Fprintf(os.Stderr, "[zeromcp] %s: Tool symbol is wrong type\n", rel)
		return
	}

	name := s.buildName(path, rootDir)

	s.Tools[name] = Tool{
		Description: pt.Description,
		Input:       pt.Input,
		Permissions: pt.Permissions,
		Execute:     pt.Execute,
	}

	fmt.Fprintf(os.Stderr, "[zeromcp] Loaded plugin: %s\n", name)
}

// RegisterAll adds all scanned tools to a server.
func (s *Scanner) RegisterAll(srv *Server) {
	for name, tool := range s.Tools {
		srv.Tool(name, tool)
	}
}
