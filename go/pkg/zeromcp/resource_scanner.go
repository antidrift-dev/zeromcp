package zeromcp

import (
	"fmt"
	"os"
	"path/filepath"
	"plugin"
	"regexp"
	"strings"
)

var resourceMimeMap = map[string]string{
	".json": "application/json",
	".txt":  "text/plain",
	".md":   "text/markdown",
	".html": "text/html",
	".xml":  "application/xml",
	".yaml": "text/yaml",
	".yml":  "text/yaml",
	".csv":  "text/csv",
	".css":  "text/css",
	".js":   "application/javascript",
	".ts":   "text/typescript",
	".sql":  "text/plain",
	".sh":   "text/plain",
	".py":   "text/plain",
	".rb":   "text/plain",
	".go":   "text/plain",
	".rs":   "text/plain",
	".toml": "text/plain",
	".ini":  "text/plain",
	".env":  "text/plain",
}

// lastExtRe strips the final ".ext" the way Node's scanners do
// (relPath.replace(/\.[^.]+$/, ”)).
var lastExtRe = regexp.MustCompile(`\.[^.]+$`)

// ResourceScanner discovers resources from the directories in Config.Resources.
// Static files are served as-is. Go plugins (.so) export a "Resource" symbol
// of type *ResourceDef or a "ResourceTemplate" symbol of type *ResourceTemplateDef.
type ResourceScanner struct {
	Resources map[string]ResourceDef
	Templates map[string]ResourceTemplateDef
	dirs      []string
	separator string
}

// NewResourceScanner creates a scanner for cfg.Resources (none when unset).
func NewResourceScanner(cfg Config) *ResourceScanner {
	sep := cfg.Separator
	if sep == "" {
		sep = "_"
	}
	return &ResourceScanner{
		Resources: map[string]ResourceDef{},
		Templates: map[string]ResourceTemplateDef{},
		dirs:      sourceDirs(cfg.Resources),
		separator: sep,
	}
}

// Scan walks every resource directory. Unreadable directories are skipped.
func (r *ResourceScanner) Scan() {
	r.Resources = map[string]ResourceDef{}
	r.Templates = map[string]ResourceTemplateDef{}
	for _, dir := range r.dirs {
		r.scanDir(dir, dir)
	}
}

func (r *ResourceScanner) scanDir(baseDir, currentDir string) {
	entries, err := os.ReadDir(currentDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		fullPath := filepath.Join(currentDir, entry.Name())
		if entry.IsDir() {
			r.scanDir(baseDir, fullPath)
			continue
		}
		if !entry.Type().IsRegular() {
			continue
		}

		ext := nodeExtname(entry.Name())
		relPath, _ := filepath.Rel(baseDir, fullPath)
		name := scannedName(relPath, r.separator)

		if ext == ".so" {
			r.loadDynamic(fullPath, name)
		} else {
			r.loadStatic(fullPath, relPath, name, ext)
		}
	}
}

func (r *ResourceScanner) loadDynamic(filePath, name string) {
	p, err := plugin.Open(filePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] Failed to load resource %s: %v\n", filePath, err)
		return
	}

	if sym, err := p.Lookup("ResourceTemplate"); err == nil {
		def, ok := sym.(*ResourceTemplateDef)
		if !ok {
			fmt.Fprintf(os.Stderr, "[zeromcp] Failed to load resource %s: ResourceTemplate symbol is wrong type\n", filePath)
			return
		}
		t := *def
		if t.MimeType == "" {
			t.MimeType = "text/plain"
		}
		r.Templates[name] = t
		return
	}

	sym, err := p.Lookup("Resource")
	if err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] Failed to load resource %s: %v\n", filePath, err)
		return
	}
	def, ok := sym.(*ResourceDef)
	if !ok {
		fmt.Fprintf(os.Stderr, "[zeromcp] Failed to load resource %s: Resource symbol is wrong type\n", filePath)
		return
	}
	res := *def
	if res.URI == "" {
		res.URI = "resource:///" + name
	}
	if res.MimeType == "" {
		res.MimeType = "application/json"
	}
	r.Resources[name] = res
}

func (r *ResourceScanner) loadStatic(filePath, relPath, name, ext string) {
	mimeType, ok := resourceMimeMap[ext]
	if !ok {
		mimeType = "application/octet-stream"
	}
	r.Resources[name] = ResourceDef{
		URI:         "resource:///" + filepath.ToSlash(relPath),
		Description: "Static resource: " + relPath,
		MimeType:    mimeType,
		Read: func() (string, error) {
			data, err := os.ReadFile(filePath)
			if err != nil {
				return "", err
			}
			return string(data), nil
		},
	}
}

// RegisterAll adds all scanned resources and templates to a server.
func (r *ResourceScanner) RegisterAll(srv *Server) {
	for name, def := range r.Resources {
		srv.Resource(name, def)
	}
	for name, def := range r.Templates {
		srv.ResourceTemplate(name, def)
	}
}

// sourceDirs resolves a Resources/Prompts config value to directory paths.
// Unlike tools, an unset value means no directories.
func sourceDirs(v any) []string {
	if v == nil {
		return nil
	}
	if s, ok := v.(string); ok && s == "" {
		return nil
	}
	sources := ResolveToolSources(v)
	dirs := make([]string, 0, len(sources))
	for _, src := range sources {
		dirs = append(dirs, src.Path)
	}
	return dirs
}

// scannedName turns a path relative to its source into a resource/prompt
// name: final extension stripped, path separators replaced with sep.
func scannedName(relPath, sep string) string {
	name := lastExtRe.ReplaceAllString(relPath, "")
	name = strings.ReplaceAll(name, "/", sep)
	name = strings.ReplaceAll(name, "\\", sep)
	return name
}

// nodeExtname matches Node's path.extname: a leading dot alone is not an extension.
func nodeExtname(base string) string {
	ext := filepath.Ext(base)
	if ext == base {
		return ""
	}
	return ext
}
