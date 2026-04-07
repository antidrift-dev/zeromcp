package zeromcp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
)

const version = "0.1.1"
const protocolVersion = "2024-11-05"

// Tool defines an MCP tool with its schema, permissions, and execute function.
type Tool struct {
	Description string
	Input       Input
	Permissions *Permissions
	Execute     func(args map[string]any, ctx *Ctx) (any, error)
}

// Server is a zero-config MCP server.
type Server struct {
	mu    sync.RWMutex
	tools map[string]*registeredTool
	cfg   Config
}

type registeredTool struct {
	tool         Tool
	ctx          *Ctx
	cachedSchema JsonSchema
}

// JSON-RPC types
type jsonRPCRequest struct {
	JSONRPC string         `json:"jsonrpc"`
	ID      any            `json:"id,omitempty"`
	Method  string         `json:"method"`
	Params  map[string]any `json:"params,omitempty"`
}

type jsonRPCResponse struct {
	JSONRPC string       `json:"jsonrpc"`
	ID      any          `json:"id,omitempty"`
	Result  any          `json:"result,omitempty"`
	Error   *jsonRPCErr  `json:"error,omitempty"`
}

type jsonRPCErr struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// NewServer creates a new MCP server with default configuration.
func NewServer() *Server {
	return &Server{
		tools: make(map[string]*registeredTool),
	}
}

// NewServerWithConfig creates a new MCP server with the given configuration.
func NewServerWithConfig(cfg Config) *Server {
	return &Server{
		tools: make(map[string]*registeredTool),
		cfg:   cfg,
	}
}

// Tool registers a tool with the server.
func (s *Server) Tool(name string, t Tool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	ValidatePermissions(name, t.Permissions)

	var creds any
	if s.cfg.Credentials != nil {
		// Tools don't have directory-based credential lookup in Go mode.
		// Credentials can be set per-tool via the config.
	}

	ctx := NewContext(name, t.Permissions, SandboxOptions{
		Logging: s.cfg.Logging,
		Bypass:  s.cfg.BypassPermissions,
	}, creds)

	s.tools[name] = &registeredTool{tool: t, ctx: ctx, cachedSchema: ToJsonSchema(t.Input)}
	fmt.Fprintf(os.Stderr, "[zeromcp] Registered: %s\n", name)
}

// Serve starts the server on the configured transports.
// Default is stdio. Call this as the last line in main().
func (s *Server) Serve() {
	transports := ResolveTransports(s.cfg)
	hasHTTP := false
	for _, t := range transports {
		if t.Type == "http" {
			hasHTTP = true
		}
	}

	for _, t := range transports {
		switch t.Type {
		case "stdio":
			go s.serveStdio(hasHTTP)
		case "http":
			port := t.Port
			if port == 0 {
				port = 4242
			}
			go s.serveHTTP(port, t.Auth)
		}
	}

	fmt.Fprintf(os.Stderr, "[zeromcp] %d tool(s) ready\n", len(s.tools))

	// Block forever
	select {}
}

// ServeStdio starts only the stdio transport (convenience for simple use).
func (s *Server) ServeStdio() {
	fmt.Fprintf(os.Stderr, "[zeromcp] %d tool(s) ready\n", len(s.tools))
	s.serveStdio(false)
}

func (s *Server) serveStdio(httpAlso bool) {
	fmt.Fprintf(os.Stderr, "[zeromcp] stdio transport ready\n")
	scanner := bufio.NewScanner(os.Stdin)
	// Increase buffer size for large requests (10MB to handle giant_string payloads)
	const maxBuf = 10 * 1024 * 1024
	scanner.Buffer(make([]byte, 0, maxBuf), maxBuf)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		out := s.HandleRequestBytes(line)
		if out == nil {
			continue
		}
		fmt.Fprintf(os.Stdout, "%s\n", out)
	}

	if !httpAlso {
		os.Exit(0)
	}
}

func (s *Server) serveHTTP(port int, authConfig string) {
	expectedToken := ResolveAuth(authConfig)

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "OPTIONS" {
			writeCORS(w)
			return
		}
		if r.Method != "GET" {
			httpJSON(w, map[string]string{"error": "Method not allowed"}, 405)
			return
		}
		setCORS(w)
		s.mu.RLock()
		count := len(s.tools)
		s.mu.RUnlock()
		httpJSON(w, map[string]any{"status": "ok", "tools": count}, 200)
	})

	mux.HandleFunc("/mcp", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "OPTIONS" {
			writeCORS(w)
			return
		}
		if r.Method != "POST" {
			httpJSON(w, map[string]string{"error": "Method not allowed"}, 405)
			return
		}
		setCORS(w)

		// Auth check
		if expectedToken != "" {
			auth := r.Header.Get("Authorization")
			if auth != "Bearer "+expectedToken {
				httpJSON(w, map[string]string{"error": "Unauthorized"}, 401)
				return
			}
		}

		body, err := readBody(r.Body)
		if err != nil {
			httpJSON(w, jsonRPCResponse{JSONRPC: "2.0", Error: &jsonRPCErr{Code: -32700, Message: "Parse error"}}, 200)
			return
		}

		out := s.HandleRequestBytes(body)
		if out == nil {
			httpJSON(w, jsonRPCResponse{JSONRPC: "2.0", Result: map[string]any{}}, 200)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		w.Write(out)
		w.Write([]byte("\n"))
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "OPTIONS" {
			writeCORS(w)
			return
		}
		setCORS(w)
		httpJSON(w, map[string]any{
			"error": "Not found",
			"endpoints": map[string]string{
				"POST /mcp":   "MCP JSON-RPC",
				"GET /health": "Health check",
			},
		}, 404)
	})

	fmt.Fprintf(os.Stderr, "[zeromcp] http transport ready on port %d\n", port)
	if err := http.ListenAndServe(fmt.Sprintf(":%d", port), mux); err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] HTTP server error: %v\n", err)
	}
}

func setCORS(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
}

func writeCORS(w http.ResponseWriter) {
	setCORS(w)
	w.WriteHeader(204)
}

func readBody(r io.ReadCloser) ([]byte, error) {
	defer r.Close()
	return io.ReadAll(r)
}

func httpJSON(w http.ResponseWriter, data any, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

// HandleRequestBytes processes raw JSON-RPC bytes and returns raw JSON bytes.
// Returns nil for notifications that require no response.
// This avoids the map[string]any marshal/unmarshal round-trip of HandleRequest.
func (s *Server) HandleRequestBytes(raw []byte) []byte {
	var req jsonRPCRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		b, _ := json.Marshal(jsonRPCResponse{
			JSONRPC: "2.0",
			Error:   &jsonRPCErr{Code: -32700, Message: "Parse error"},
		})
		return b
	}

	resp := s.handleRequest(req)
	if resp == nil {
		return nil
	}

	b, err := json.Marshal(resp)
	if err != nil {
		return nil
	}
	return b
}

// HandleRequest processes a single JSON-RPC request and returns a response.
// Returns nil for notifications that require no response.
//
// Usage:
//
//	resp := server.HandleRequest(map[string]any{
//	    "jsonrpc": "2.0", "id": 1, "method": "tools/list",
//	})
func (s *Server) HandleRequest(request map[string]any) map[string]any {
	raw, err := json.Marshal(request)
	if err != nil {
		return map[string]any{
			"jsonrpc": "2.0",
			"error":   map[string]any{"code": -32700, "message": "Parse error"},
		}
	}

	out := s.HandleRequestBytes(raw)
	if out == nil {
		return nil
	}

	var result map[string]any
	json.Unmarshal(out, &result)
	return result
}

func (s *Server) handleRequest(req jsonRPCRequest) *jsonRPCResponse {
	// Notifications (no id) for initialized
	if req.ID == nil && req.Method == "notifications/initialized" {
		return nil
	}

	switch req.Method {
	case "initialize":
		return &jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"protocolVersion": protocolVersion,
				"capabilities": map[string]any{
					"tools": map[string]any{"listChanged": true},
				},
				"serverInfo": map[string]any{
					"name":    "zeromcp",
					"version": version,
				},
			},
		}

	case "tools/list":
		return &jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"tools": s.buildToolList(),
			},
		}

	case "tools/call":
		return &jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result:  s.callTool(req.Params),
		}

	case "ping":
		return &jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result:  map[string]any{},
		}

	default:
		if req.ID == nil {
			return nil
		}
		return &jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &jsonRPCErr{Code: -32601, Message: fmt.Sprintf("Method not found: %s", req.Method)},
		}
	}
}

func (s *Server) buildToolList() []map[string]any {
	s.mu.RLock()
	defer s.mu.RUnlock()

	list := make([]map[string]any, 0, len(s.tools))
	for name, rt := range s.tools {
		list = append(list, map[string]any{
			"name":        name,
			"description": rt.tool.Description,
			"inputSchema": rt.cachedSchema,
		})
	}
	return list
}

func (s *Server) callTool(params map[string]any) map[string]any {
	name, _ := params["name"].(string)
	args, _ := params["arguments"].(map[string]any)
	if args == nil {
		args = map[string]any{}
	}

	s.mu.RLock()
	rt, ok := s.tools[name]
	s.mu.RUnlock()

	if !ok {
		return map[string]any{
			"content": []map[string]any{{"type": "text", "text": fmt.Sprintf("Unknown tool: %s", name)}},
			"isError": true,
		}
	}

	errors := Validate(args, rt.cachedSchema)
	if len(errors) > 0 {
		msg := "Validation errors:\n"
		for _, e := range errors {
			msg += e + "\n"
		}
		return map[string]any{
			"content": []map[string]any{{"type": "text", "text": msg}},
			"isError": true,
		}
	}

	// Determine execute timeout: tool-level overrides config default, fallback 30s
	timeoutMs := s.cfg.ExecuteTimeout
	if rt.tool.Permissions != nil && rt.tool.Permissions.ExecuteTimeout > 0 {
		timeoutMs = rt.tool.Permissions.ExecuteTimeout
	}
	if timeoutMs <= 0 {
		timeoutMs = 30000
	}

	type executeResult struct {
		val any
		err error
	}
	ch := make(chan executeResult, 1)
	go func() {
		v, e := rt.tool.Execute(args, rt.ctx)
		ch <- executeResult{v, e}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()

	var result any
	var err error
	select {
	case <-ctx.Done():
		return map[string]any{
			"content": []map[string]any{{"type": "text", "text": fmt.Sprintf("Tool %q timed out after %dms", name, timeoutMs)}},
			"isError": true,
		}
	case res := <-ch:
		result = res.val
		err = res.err
	}

	if err != nil {
		return map[string]any{
			"content": []map[string]any{{"type": "text", "text": fmt.Sprintf("Error: %s", err.Error())}},
			"isError": true,
		}
	}

	var text string
	switch v := result.(type) {
	case string:
		text = v
	default:
		b, _ := json.Marshal(result)
		text = string(b)
	}

	return map[string]any{
		"content": []map[string]any{{"type": "text", "text": text}},
	}
}
