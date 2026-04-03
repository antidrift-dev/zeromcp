// Example Go plugin tool.
// Build: go build -buildmode=plugin -o hello.so ./examples/plugin/hello.go
// Place the .so file in your ./tools/ directory.
package main

import (
	"fmt"

	"github.com/probeo-io/zeromcp/pkg/zeromcp"
)

// Tool is the exported symbol that the scanner looks for.
var Tool = zeromcp.PluginTool{
	Description: "Say hello to someone",
	Input:       zeromcp.Input{"name": "string"},
	Permissions: nil,
	Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
		name, _ := args["name"].(string)
		return fmt.Sprintf("Hello, %s!", name), nil
	},
}
