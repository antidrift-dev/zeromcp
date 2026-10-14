// Chaos monkey test binary — registers normal + chaos tools.
package main

import (
	"fmt"
	"time"

	"github.com/antidrift-dev/zeromcp-go/pkg/zeromcp"
)

var leaks [][]byte

func main() {
	s := zeromcp.NewServer()

	// Normal tool for health checks
	s.Tool("hello", zeromcp.Tool{
		Description: "Say hello",
		Input:       zeromcp.Input{"name": "string"},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			return fmt.Sprintf("Hello, %s!", args["name"]), nil
		},
	})

	// Tool that throws
	s.Tool("throw_error", zeromcp.Tool{
		Description: "Tool that throws",
		Input:       zeromcp.Input{},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			return nil, fmt.Errorf("Intentional chaos: unhandled exception")
		},
	})

	// Tool that hangs — uses goroutine so server doesn't block
	s.Tool("hang", zeromcp.Tool{
		Description: "Tool that hangs forever",
		Input:       zeromcp.Input{},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			select {} // block forever
		},
	})

	// Tool that takes 3 seconds
	s.Tool("slow", zeromcp.Tool{
		Description: "Tool that takes 3 seconds",
		Input:       zeromcp.Input{},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			time.Sleep(3 * time.Second)
			return map[string]any{"status": "ok", "delay_ms": 3000}, nil
		},
	})

	// Tool that leaks memory
	s.Tool("leak_memory", zeromcp.Tool{
		Description: "Tool that leaks memory",
		Input:       zeromcp.Input{},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			leaks = append(leaks, make([]byte, 1024*1024))
			return map[string]any{"leaked_buffers": len(leaks), "total_mb": len(leaks)}, nil
		},
	})

	// Tool that writes to stdout (corrupts JSON-RPC stream)
	s.Tool("stdout_corrupt", zeromcp.Tool{
		Description: "Tool that writes to stdout",
		Input:       zeromcp.Input{},
		Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
			fmt.Println("CORRUPTED OUTPUT")
			return map[string]any{"status": "ok"}, nil
		},
	})

	s.ServeStdio()
}
