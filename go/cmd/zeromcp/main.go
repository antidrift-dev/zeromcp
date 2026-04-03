package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/probeo-io/zeromcp/pkg/zeromcp"
)

func main() {
	args := os.Args[1:]

	if len(args) > 0 && args[0] == "audit" {
		runAudit(args[1:])
		return
	}

	if len(args) > 0 && args[0] == "version" {
		fmt.Println("zeromcp 0.1.0 (go)")
		return
	}

	if len(args) > 0 && (args[0] == "help" || args[0] == "-h" || args[0] == "--help") {
		printHelp()
		return
	}

	// Default: start server with plugin scanning
	runServer(args)
}

func runServer(args []string) {
	configPath := "zeromcp.config.json"
	toolsDir := "./tools"

	// Parse flags
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--config", "-c":
			if i+1 < len(args) {
				configPath = args[i+1]
				i++
			}
		case "--tools", "-t":
			if i+1 < len(args) {
				toolsDir = args[i+1]
				i++
			}
		}
	}

	cfg, err := zeromcp.LoadConfig(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] Config error: %v\n", err)
		os.Exit(1)
	}

	srv := zeromcp.NewServerWithConfig(cfg)

	// Try to scan for plugin .so files
	absDir, _ := filepath.Abs(toolsDir)
	scanner := zeromcp.NewScanner(absDir, cfg)
	if err := scanner.Scan(); err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] No tools directory found at %s\n", absDir)
		fmt.Fprintf(os.Stderr, "[zeromcp] Starting with 0 tools. Use the library API to register tools in code.\n")
	} else {
		scanner.RegisterAll(srv)
	}

	srv.Serve()
}

func runAudit(args []string) {
	dir := "./tools"
	if len(args) > 0 {
		dir = args[0]
	}

	absDir, _ := filepath.Abs(dir)
	violations, err := zeromcp.AuditDir(absDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] Audit error: %v\n", err)
		os.Exit(1)
	}

	fmt.Print(zeromcp.FormatAuditResults(violations))

	if len(violations) > 0 {
		os.Exit(1)
	}
}

func printHelp() {
	help := "zeromcp - zero-config MCP runtime (Go)\n" +
		"\n" +
		"Usage:\n" +
		"  zeromcp                        Start the MCP server\n" +
		"  zeromcp --tools ./my-tools     Specify tools directory\n" +
		"  zeromcp --config config.json   Specify config file\n" +
		"  zeromcp audit [dir]            Audit tool files for sandbox violations\n" +
		"  zeromcp version                Print version\n" +
		"\n" +
		"The server reads tools as Go plugins (.so files) from ./tools/\n" +
		"or use the library API for compiled-in tools.\n" +
		"\n" +
		"Config: zeromcp.config.json (optional)\n"
	fmt.Print(help)
}
