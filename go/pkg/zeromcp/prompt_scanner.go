package zeromcp

import (
	"fmt"
	"os"
	"path/filepath"
	"plugin"
)

// PromptScanner discovers prompts from the directories in Config.Prompts.
// Only Go plugins (.so) are loaded; each exports a "Prompt" symbol of type *PromptDef.
type PromptScanner struct {
	Prompts   map[string]PromptDef
	dirs      []string
	separator string
}

// NewPromptScanner creates a scanner for cfg.Prompts (none when unset).
func NewPromptScanner(cfg Config) *PromptScanner {
	sep := cfg.Separator
	if sep == "" {
		sep = "_"
	}
	return &PromptScanner{
		Prompts:   map[string]PromptDef{},
		dirs:      sourceDirs(cfg.Prompts),
		separator: sep,
	}
}

// Scan walks every prompt directory. Unreadable directories are skipped.
func (p *PromptScanner) Scan() {
	p.Prompts = map[string]PromptDef{}
	for _, dir := range p.dirs {
		p.scanDir(dir, dir)
	}
}

func (p *PromptScanner) scanDir(baseDir, currentDir string) {
	entries, err := os.ReadDir(currentDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		fullPath := filepath.Join(currentDir, entry.Name())
		if entry.IsDir() {
			p.scanDir(baseDir, fullPath)
			continue
		}
		if !entry.Type().IsRegular() {
			continue
		}
		if nodeExtname(entry.Name()) != ".so" {
			continue
		}
		relPath, _ := filepath.Rel(baseDir, fullPath)
		p.loadPrompt(fullPath, scannedName(relPath, p.separator))
	}
}

func (p *PromptScanner) loadPrompt(filePath, name string) {
	plug, err := plugin.Open(filePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] Failed to load prompt %s: %v\n", filePath, err)
		return
	}
	sym, err := plug.Lookup("Prompt")
	if err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] Failed to load prompt %s: %v\n", filePath, err)
		return
	}
	def, ok := sym.(*PromptDef)
	if !ok {
		fmt.Fprintf(os.Stderr, "[zeromcp] Failed to load prompt %s: Prompt symbol is wrong type\n", filePath)
		return
	}
	if def.Render == nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] Prompt %s: missing render() function\n", filePath)
		return
	}
	p.Prompts[name] = *def
}

// RegisterAll adds all scanned prompts to a server.
func (p *PromptScanner) RegisterAll(srv *Server) {
	for name, def := range p.Prompts {
		srv.Prompt(name, def)
	}
}
