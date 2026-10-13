package zeromcp

import (
	"fmt"
	"os"
	"path/filepath"
	"plugin"
	"sort"
	"strings"
	"sync"
	"time"
)

// PluginTool is the interface that Go plugin files must export.
// Plugin .so files must have a variable named "Tool" of this type.
type PluginTool struct {
	Description string
	Input       Input
	Permissions *Permissions
	Route       *RouteConfig
	Execute     func(args map[string]any, ctx *Ctx) (any, error)
}

// Scanner finds and loads tool plugins from one or more source directories.
type Scanner struct {
	Tools        map[string]Tool
	sources      []ToolSource
	separator    string
	cfg          Config
	pollInterval time.Duration
}

// NewScanner creates a scanner for a single tools directory.
func NewScanner(dir string, cfg Config) *Scanner {
	return newScanner([]ToolSource{{Path: dir}}, cfg)
}

// NewScannerFromConfig creates a scanner for the sources in cfg.Tools
// (default ./tools). Relative paths resolve against the working directory.
func NewScannerFromConfig(cfg Config) *Scanner {
	sources := ResolveToolSources(cfg.Tools)
	for i := range sources {
		if abs, err := filepath.Abs(sources[i].Path); err == nil {
			sources[i].Path = abs
		}
	}
	return newScanner(sources, cfg)
}

func newScanner(sources []ToolSource, cfg Config) *Scanner {
	sep := cfg.Separator
	if sep == "" {
		sep = "_"
	}
	return &Scanner{
		Tools:        make(map[string]Tool),
		sources:      sources,
		separator:    sep,
		cfg:          cfg,
		pollInterval: time.Second,
	}
}

// Scan walks each source directory looking for .so plugin files.
// Each plugin must export a "Tool" symbol of type *PluginTool.
// An unreadable source is logged and skipped; Scan returns an error only
// when no source could be read.
func (s *Scanner) Scan() error {
	s.Tools = make(map[string]Tool)
	var lastErr error
	readable := 0
	for _, src := range s.sources {
		if err := s.scanDir(src.Path, src.Path, src.Prefix); err != nil {
			lastErr = err
			continue
		}
		readable++
	}
	if readable == 0 && lastErr != nil {
		return lastErr
	}
	return nil
}

func (s *Scanner) scanDir(dir, rootDir, sourcePrefix string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] Cannot read tools directory: %s\n", dir)
		return err
	}

	for _, entry := range entries {
		fullPath := filepath.Join(dir, entry.Name())

		if entry.IsDir() {
			s.scanDir(fullPath, rootDir, sourcePrefix)
			continue
		}

		if !entry.Type().IsRegular() {
			continue
		}
		if filepath.Ext(entry.Name()) != ".so" {
			continue
		}

		s.loadPlugin(fullPath, rootDir, sourcePrefix)
	}

	return nil
}

func (s *Scanner) buildName(filePath, rootDir, sourcePrefix string) string {
	rel, _ := filepath.Rel(rootDir, filePath)
	parts := strings.Split(rel, string(filepath.Separator))
	filename := parts[len(parts)-1]
	name := strings.TrimSuffix(filename, filepath.Ext(filename))

	if len(parts) > 1 {
		dirName := parts[0]
		dirPrefix := dirName
		if override, ok := s.cfg.Namespacing[dirName]; ok && override.Prefix != nil {
			dirPrefix = *override.Prefix
		}
		if dirPrefix != "" {
			name = dirPrefix + s.separator + name
		}
	}

	if sourcePrefix != "" {
		name = sourcePrefix + s.separator + name
	}

	return name
}

func (s *Scanner) loadPlugin(path, rootDir, sourcePrefix string) {
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

	name := s.buildName(path, rootDir, sourcePrefix)

	s.Tools[name] = Tool{
		Description: pt.Description,
		Input:       pt.Input,
		Permissions: pt.Permissions,
		Route:       pt.Route,
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

type soStamp struct {
	mod  time.Time
	size int64
}

// snapshot maps every .so under the scanner's sources to its modtime/size,
// keyed by absolute path, with the path relative to its source alongside.
func (s *Scanner) snapshot() (map[string]soStamp, map[string]string) {
	stamps := map[string]soStamp{}
	rels := map[string]string{}
	for _, src := range s.sources {
		root := src.Path
		filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() || !d.Type().IsRegular() || filepath.Ext(path) != ".so" {
				return nil
			}
			info, err := d.Info()
			if err != nil {
				return nil
			}
			stamps[path] = soStamp{mod: info.ModTime(), size: info.Size()}
			rel, _ := filepath.Rel(root, path)
			rels[path] = rel
			return nil
		})
	}
	return stamps, rels
}

// Watch polls the scanner's source directories for .so changes and calls
// onChange after rescanning. Only added or changed .so files trigger a
// rescan. The returned stop function ends polling.
//
// Go's plugin.Open returns the already-loaded plugin for a path it has
// opened before, so a .so rebuilt in place keeps its old code; only .so
// files at new paths take effect.
func (s *Scanner) Watch(onChange func()) (stop func()) {
	prev, _ := s.snapshot()
	done := make(chan struct{})
	var once sync.Once

	go func() {
		ticker := time.NewTicker(s.pollInterval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
			}

			cur, rels := s.snapshot()
			var changed []string
			for path, st := range cur {
				if old, ok := prev[path]; !ok || !old.mod.Equal(st.mod) || old.size != st.size {
					changed = append(changed, path)
				}
			}
			prev = cur
			if len(changed) == 0 {
				continue
			}
			sort.Strings(changed)
			for _, path := range changed {
				fmt.Fprintf(os.Stderr, "[zeromcp] Change detected: %s\n", rels[path])
			}

			select {
			case <-done:
				return
			default:
			}
			s.Scan()
			if onChange != nil {
				onChange()
			}
		}
	}()

	return func() { once.Do(func() { close(done) }) }
}
