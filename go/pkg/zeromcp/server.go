package zeromcp

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const version = "0.2.0"
const protocolVersion = "2024-11-05"

// Tool defines an MCP tool with its schema, permissions, and execute function.
type Tool struct {
	Description string
	Input       Input
	Permissions *Permissions
	Execute     func(args map[string]any, ctx *Ctx) (any, error)
}

// ResourceDef defines an MCP resource with a fixed URI.
type ResourceDef struct {
	URI         string
	Description string
	MimeType    string
	Read        func() (string, error)
}

// ResourceTemplateDef defines an MCP resource template with a URI template.
type ResourceTemplateDef struct {
	UriTemplate string
	Description string
	MimeType    string
	Read        func(params map[string]string) (string, error)
}

// PromptArgument describes a single argument for a prompt.
type PromptArgument struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Required    bool   `json:"required,omitempty"`
}

// PromptMessage is a single message returned by a prompt's Render function.
type PromptMessage struct {
	Role    string `json:"role"`
	Content any    `json:"content"`
}

// PromptDef defines an MCP prompt.
type PromptDef struct {
	Description string
	Arguments   []PromptArgument
	Render      func(args map[string]any) ([]PromptMessage, error)
}

// Server is a zero-config MCP server.
type Server struct {
	mu                sync.RWMutex
	tools             map[string]*registeredTool
	resources         map[string]*registeredResource
	templates         map[string]*registeredTemplate
	prompts           map[string]*registeredPrompt
	subscriptions     map[string]bool
	logLevel          string
	cfg               Config
	credentialCache   map[string]any
}

type registeredTool struct {
	tool         Tool
	ctx          *Ctx
	cachedSchema JsonSchema
}

type registeredResource struct {
	name string
	def  ResourceDef
}

type registeredTemplate struct {
	name string
	def  ResourceTemplateDef
}

type registeredPrompt struct {
	name string
	def  PromptDef
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
	return newServer(Config{})
}

// NewServerWithConfig creates a new MCP server with the given configuration.
func NewServerWithConfig(cfg Config) *Server {
	return newServer(cfg)
}

func newServer(cfg Config) *Server {
	// Resolve icon at startup
	icon := resolveIcon(cfg.Icon)
	cfg.Icon = icon

	return &Server{
		tools:           make(map[string]*registeredTool),
		resources:       make(map[string]*registeredResource),
		templates:       make(map[string]*registeredTemplate),
		prompts:         make(map[string]*registeredPrompt),
		subscriptions:   make(map[string]bool),
		logLevel:        "info",
		cfg:             cfg,
		credentialCache: make(map[string]any),
	}
}

// ResolveToolCredentials resolves credentials for the given namespace key.
// When CacheCredentials is true (default), caches after first read. Set false to read fresh on every call.
func (s *Server) ResolveToolCredentials(ns string) any {
	source, ok := s.cfg.Credentials[ns]
	if !ok {
		return nil
	}
	if s.cfg.CacheCredentials == nil || !*s.cfg.CacheCredentials {
		return ResolveCredentials(source)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if cached, hit := s.credentialCache[ns]; hit {
		return cached
	}
	creds := ResolveCredentials(source)
	s.credentialCache[ns] = creds
	return creds
}

// resolveIcon resolves an icon path to a data URI at startup.
// Supports: data URIs (passthrough), http(s) URLs (passthrough), file paths (base64 encode).
func resolveIcon(icon string) string {
	if icon == "" {
		return ""
	}
	if strings.HasPrefix(icon, "data:") || strings.HasPrefix(icon, "http://") || strings.HasPrefix(icon, "https://") {
		return icon
	}
	// Treat as file path — read and base64-encode
	data, err := os.ReadFile(icon)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[zeromcp] Warning: cannot read icon file %s: %v\n", icon, err)
		return ""
	}
	mime := "image/png"
	if strings.HasSuffix(icon, ".svg") {
		mime = "image/svg+xml"
	} else if strings.HasSuffix(icon, ".jpg") || strings.HasSuffix(icon, ".jpeg") {
		mime = "image/jpeg"
	}
	return fmt.Sprintf("data:%s;base64,%s", mime, base64.StdEncoding.EncodeToString(data))
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
	fmt.Fprintf(os.Stderr, "[zeromcp] Registered tool: %s\n", name)
}

// Resource registers a resource with the server.
func (s *Server) Resource(name string, r ResourceDef) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.resources[name] = &registeredResource{name: name, def: r}
	fmt.Fprintf(os.Stderr, "[zeromcp] Registered resource: %s\n", name)
}

// ResourceTemplate registers a resource template with the server.
func (s *Server) ResourceTemplate(name string, t ResourceTemplateDef) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.templates[name] = &registeredTemplate{name: name, def: t}
	fmt.Fprintf(os.Stderr, "[zeromcp] Registered template: %s\n", name)
}

// Prompt registers a prompt with the server.
func (s *Server) Prompt(name string, p PromptDef) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prompts[name] = &registeredPrompt{name: name, def: p}
	fmt.Fprintf(os.Stderr, "[zeromcp] Registered prompt: %s\n", name)
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

	s.logReadyCounts()

	// Block forever
	select {}
}

// ServeStdio starts only the stdio transport (convenience for simple use).
func (s *Server) ServeStdio() {
	s.logReadyCounts()
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
	// Notifications (no id)
	if req.ID == nil {
		s.handleNotification(req.Method, req.Params)
		return nil
	}

	switch req.Method {
	case "initialize":
		return s.handleInitialize(req)

	case "ping":
		return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{}}

	// Tools
	case "tools/list":
		return s.handleToolsList(req)
	case "tools/call":
		return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: s.callTool(req.Params)}

	// Resources
	case "resources/list":
		return s.handleResourcesList(req)
	case "resources/read":
		return s.handleResourcesRead(req)
	case "resources/subscribe":
		return s.handleResourcesSubscribe(req)
	case "resources/templates/list":
		return s.handleResourcesTemplatesList(req)

	// Prompts
	case "prompts/list":
		return s.handlePromptsList(req)
	case "prompts/get":
		return s.handlePromptsGet(req)

	// Passthrough
	case "logging/setLevel":
		return s.handleLoggingSetLevel(req)
	case "completion/complete":
		return s.handleCompletionComplete(req)

	default:
		return &jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &jsonRPCErr{Code: -32601, Message: fmt.Sprintf("Method not found: %s", req.Method)},
		}
	}
}

func (s *Server) handleNotification(method string, params map[string]any) {
	switch method {
	case "notifications/initialized":
		// no-op
	case "notifications/roots/list_changed":
		// could store roots if needed
	}
}

func (s *Server) handleInitialize(req jsonRPCRequest) *jsonRPCResponse {
	capabilities := map[string]any{
		"tools": map[string]any{"listChanged": true},
	}

	s.mu.RLock()
	hasResources := len(s.resources) > 0 || len(s.templates) > 0
	hasPrompts := len(s.prompts) > 0
	s.mu.RUnlock()

	if hasResources {
		capabilities["resources"] = map[string]any{"subscribe": true, "listChanged": true}
	}
	if hasPrompts {
		capabilities["prompts"] = map[string]any{"listChanged": true}
	}
	capabilities["logging"] = map[string]any{}

	return &jsonRPCResponse{
		JSONRPC: "2.0",
		ID:      req.ID,
		Result: map[string]any{
			"protocolVersion": protocolVersion,
			"capabilities":    capabilities,
			"serverInfo": map[string]any{
				"name":    "zeromcp",
				"version": version,
			},
		},
	}
}

// --- Tools ---

func (s *Server) handleToolsList(req jsonRPCRequest) *jsonRPCResponse {
	cursor, _ := req.Params["cursor"].(string)
	list := s.buildToolList()
	items, nextCursor := paginate(list, cursor, s.cfg.PageSize)
	result := map[string]any{"tools": items}
	if nextCursor != "" {
		result["nextCursor"] = nextCursor
	}
	return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: result}
}

// --- Resources ---

func (s *Server) handleResourcesList(req jsonRPCRequest) *jsonRPCResponse {
	cursor, _ := req.Params["cursor"].(string)
	s.mu.RLock()
	list := make([]map[string]any, 0, len(s.resources))
	// Sort for stable pagination
	names := make([]string, 0, len(s.resources))
	for name := range s.resources {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		rr := s.resources[name]
		entry := map[string]any{
			"uri":         rr.def.URI,
			"name":        rr.name,
			"description": rr.def.Description,
			"mimeType":    rr.def.MimeType,
		}
		if s.cfg.Icon != "" {
			entry["icons"] = []map[string]string{{"uri": s.cfg.Icon}}
		}
		list = append(list, entry)
	}
	s.mu.RUnlock()

	items, nextCursor := paginate(list, cursor, s.cfg.PageSize)
	result := map[string]any{"resources": items}
	if nextCursor != "" {
		result["nextCursor"] = nextCursor
	}
	return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: result}
}

func (s *Server) handleResourcesRead(req jsonRPCRequest) *jsonRPCResponse {
	uri, _ := req.Params["uri"].(string)

	s.mu.RLock()
	// Check static resources
	for _, rr := range s.resources {
		if rr.def.URI == uri {
			readFn := rr.def.Read
			mimeType := rr.def.MimeType
			s.mu.RUnlock()
			text, err := readFn()
			if err != nil {
				return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &jsonRPCErr{Code: -32603, Message: fmt.Sprintf("Error reading resource: %s", err.Error())}}
			}
			return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
				"contents": []map[string]any{{"uri": uri, "mimeType": mimeType, "text": text}},
			}}
		}
	}

	// Check templates
	for _, rt := range s.templates {
		if params := matchTemplate(rt.def.UriTemplate, uri); params != nil {
			readFn := rt.def.Read
			mimeType := rt.def.MimeType
			s.mu.RUnlock()
			text, err := readFn(params)
			if err != nil {
				return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &jsonRPCErr{Code: -32603, Message: fmt.Sprintf("Error reading resource: %s", err.Error())}}
			}
			return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
				"contents": []map[string]any{{"uri": uri, "mimeType": mimeType, "text": text}},
			}}
		}
	}
	s.mu.RUnlock()

	return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &jsonRPCErr{Code: -32002, Message: fmt.Sprintf("Resource not found: %s", uri)}}
}

func (s *Server) handleResourcesSubscribe(req jsonRPCRequest) *jsonRPCResponse {
	uri, _ := req.Params["uri"].(string)
	if uri != "" {
		s.mu.Lock()
		s.subscriptions[uri] = true
		s.mu.Unlock()
	}
	return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{}}
}

func (s *Server) handleResourcesTemplatesList(req jsonRPCRequest) *jsonRPCResponse {
	cursor, _ := req.Params["cursor"].(string)
	s.mu.RLock()
	list := make([]map[string]any, 0, len(s.templates))
	names := make([]string, 0, len(s.templates))
	for name := range s.templates {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		rt := s.templates[name]
		entry := map[string]any{
			"uriTemplate": rt.def.UriTemplate,
			"name":        rt.name,
			"description": rt.def.Description,
			"mimeType":    rt.def.MimeType,
		}
		if s.cfg.Icon != "" {
			entry["icons"] = []map[string]string{{"uri": s.cfg.Icon}}
		}
		list = append(list, entry)
	}
	s.mu.RUnlock()

	items, nextCursor := paginate(list, cursor, s.cfg.PageSize)
	result := map[string]any{"resourceTemplates": items}
	if nextCursor != "" {
		result["nextCursor"] = nextCursor
	}
	return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: result}
}

// --- Prompts ---

func (s *Server) handlePromptsList(req jsonRPCRequest) *jsonRPCResponse {
	cursor, _ := req.Params["cursor"].(string)
	s.mu.RLock()
	list := make([]map[string]any, 0, len(s.prompts))
	names := make([]string, 0, len(s.prompts))
	for name := range s.prompts {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		rp := s.prompts[name]
		entry := map[string]any{"name": rp.name}
		if rp.def.Description != "" {
			entry["description"] = rp.def.Description
		}
		if rp.def.Arguments != nil {
			entry["arguments"] = rp.def.Arguments
		}
		if s.cfg.Icon != "" {
			entry["icons"] = []map[string]string{{"uri": s.cfg.Icon}}
		}
		list = append(list, entry)
	}
	s.mu.RUnlock()

	items, nextCursor := paginate(list, cursor, s.cfg.PageSize)
	result := map[string]any{"prompts": items}
	if nextCursor != "" {
		result["nextCursor"] = nextCursor
	}
	return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: result}
}

func (s *Server) handlePromptsGet(req jsonRPCRequest) *jsonRPCResponse {
	name, _ := req.Params["name"].(string)
	args, _ := req.Params["arguments"].(map[string]any)
	if args == nil {
		args = map[string]any{}
	}

	s.mu.RLock()
	rp, ok := s.prompts[name]
	s.mu.RUnlock()

	if !ok {
		return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &jsonRPCErr{Code: -32002, Message: fmt.Sprintf("Prompt not found: %s", name)}}
	}

	messages, err := rp.def.Render(args)
	if err != nil {
		return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &jsonRPCErr{Code: -32603, Message: fmt.Sprintf("Error rendering prompt: %s", err.Error())}}
	}

	return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{"messages": messages}}
}

// --- Passthrough ---

func (s *Server) handleLoggingSetLevel(req jsonRPCRequest) *jsonRPCResponse {
	level, _ := req.Params["level"].(string)
	if level != "" {
		s.mu.Lock()
		s.logLevel = level
		s.mu.Unlock()
	}
	return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{}}
}

func (s *Server) handleCompletionComplete(req jsonRPCRequest) *jsonRPCResponse {
	return &jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
		"completion": map[string]any{"values": []string{}},
	}}
}

func (s *Server) buildToolList() []map[string]any {
	s.mu.RLock()
	defer s.mu.RUnlock()

	names := make([]string, 0, len(s.tools))
	for name := range s.tools {
		names = append(names, name)
	}
	sort.Strings(names)

	list := make([]map[string]any, 0, len(s.tools))
	for _, name := range names {
		rt := s.tools[name]
		entry := map[string]any{
			"name":        name,
			"description": rt.tool.Description,
			"inputSchema": rt.cachedSchema,
		}
		if s.cfg.Icon != "" {
			entry["icons"] = []map[string]string{{"uri": s.cfg.Icon}}
		}
		list = append(list, entry)
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

// --- Utilities ---

// paginate applies stateless cursor-based pagination. Cursor is base64-encoded offset.
// pageSize 0 means no pagination (return all items).
func paginate(items []map[string]any, cursor string, pageSize int) ([]map[string]any, string) {
	if pageSize <= 0 {
		return items, ""
	}

	offset := 0
	if cursor != "" {
		offset = decodeCursor(cursor)
	}

	if offset >= len(items) {
		return []map[string]any{}, ""
	}

	end := offset + pageSize
	if end > len(items) {
		end = len(items)
	}

	slice := items[offset:end]
	var nextCursor string
	if end < len(items) {
		nextCursor = encodeCursor(end)
	}

	return slice, nextCursor
}

func encodeCursor(offset int) string {
	return base64.StdEncoding.EncodeToString([]byte(strconv.Itoa(offset)))
}

func decodeCursor(cursor string) int {
	decoded, err := base64.StdEncoding.DecodeString(cursor)
	if err != nil {
		return 0
	}
	offset, err := strconv.Atoi(string(decoded))
	if err != nil || offset < 0 {
		return 0
	}
	return offset
}

// matchTemplate matches a URI against a URI template like "file:///{path}".
// Returns extracted parameters or nil if no match.
func matchTemplate(template, uri string) map[string]string {
	// Build regex from template: replace {name} with named capture group
	paramNames := []string{}
	regexStr := regexp.QuoteMeta(template)
	// QuoteMeta escapes braces, so we need to find \{name\} patterns
	re := regexp.MustCompile(`\\{(\w+)\\}`)
	regexStr = re.ReplaceAllStringFunc(regexStr, func(match string) string {
		// Extract param name from \{name\}
		name := match[2 : len(match)-2]
		paramNames = append(paramNames, name)
		return `([^/]+)`
	})

	compiled, err := regexp.Compile("^" + regexStr + "$")
	if err != nil {
		return nil
	}

	matches := compiled.FindStringSubmatch(uri)
	if matches == nil {
		return nil
	}

	result := make(map[string]string)
	for i, name := range paramNames {
		if i+1 < len(matches) {
			result[name] = matches[i+1]
		}
	}
	return result
}

func (s *Server) logReadyCounts() {
	s.mu.RLock()
	parts := []string{fmt.Sprintf("%d tool(s)", len(s.tools))}
	if len(s.resources) > 0 {
		parts = append(parts, fmt.Sprintf("%d resource(s)", len(s.resources)))
	}
	if len(s.templates) > 0 {
		parts = append(parts, fmt.Sprintf("%d template(s)", len(s.templates)))
	}
	if len(s.prompts) > 0 {
		parts = append(parts, fmt.Sprintf("%d prompt(s)", len(s.prompts)))
	}
	s.mu.RUnlock()
	fmt.Fprintf(os.Stderr, "[zeromcp] %s ready\n", strings.Join(parts, ", "))
}
