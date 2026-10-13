package zeromcp

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
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

// RouteConfig defines an optional HTTP route for a tool.
type RouteConfig struct {
	Method string // GET, POST, PUT, PATCH, DELETE
	Path   string // e.g. "/:domain/leads"
}

// Tool defines an MCP tool with its schema, permissions, and execute function.
type Tool struct {
	Description string
	Input       Input
	Permissions *Permissions
	Route       *RouteConfig
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
	mu              sync.RWMutex
	tools           map[string]*registeredTool
	resources       map[string]*registeredResource
	templates       map[string]*registeredTemplate
	prompts         map[string]*registeredPrompt
	subscriptions   map[string]bool
	logLevel        string
	cfg             Config
	credentialCache map[string]any
	getRuntime      func() any        // set by SetRuntime; guarded by mu
	notify          func(line []byte) // set by serveStdio; guarded by mu
	stdoutMu        sync.Mutex        // serializes stdio writes (responses and notifications)
}

type registeredTool struct {
	tool         Tool
	ctx          *Ctx
	cachedSchema JsonSchema
	remote       bool
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
	JSONRPC string      `json:"jsonrpc"`
	ID      any         `json:"id,omitempty"`
	Result  any         `json:"result,omitempty"`
	Error   *jsonRPCErr `json:"error,omitempty"`
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

	s := &Server{
		tools:           make(map[string]*registeredTool),
		resources:       make(map[string]*registeredResource),
		templates:       make(map[string]*registeredTemplate),
		prompts:         make(map[string]*registeredPrompt),
		subscriptions:   make(map[string]bool),
		logLevel:        "info",
		cfg:             cfg,
		credentialCache: make(map[string]any),
	}

	// Remote tools go in first; local registrations (Tool, Scanner.RegisterAll)
	// come later and override them. This blocks on the network, the Go
	// equivalent of Node awaiting remoteManager.connect.
	if len(cfg.Remote) > 0 {
		for _, rt := range connectRemotes(cfg.Remote) {
			ctx := NewContext(rt.name, nil, SandboxOptions{
				Logging: cfg.Logging,
				Bypass:  cfg.BypassPermissions,
			}, nil)
			t := rt.tool
			t.Route = nil
			t.Permissions = nil
			s.tools[rt.name] = &registeredTool{tool: t, ctx: ctx, cachedSchema: ToJsonSchema(t.Input), remote: true}
		}
	}

	return s
}

// SetRuntime installs a function called on every local tool execution;
// a non-nil result is exposed to the tool as ctx.Runtime. It covers the
// stdio transport, HandleRequest/HandleRequestBytes, and Registry()
// (MCP and Routes[i].Invoke).
func (s *Server) SetRuntime(get func() any) {
	s.mu.Lock()
	s.getRuntime = get
	s.mu.Unlock()
}

// execCtx returns the ctx for one execution of rt: the shared ctx, or a
// per-call copy carrying the runtime value. Must be called without s.mu held.
func (s *Server) execCtx(rt *registeredTool) *Ctx {
	if rt.remote {
		return rt.ctx
	}
	s.mu.RLock()
	get := s.getRuntime
	s.mu.RUnlock()
	if get == nil {
		return rt.ctx
	}
	v := get()
	if v == nil {
		return rt.ctx
	}
	c := *rt.ctx
	c.Runtime = v
	return &c
}

// Notify sends a JSON-RPC notification on the stdio transport; no-op if stdio isn't running.
func (s *Server) Notify(method string, params any) {
	s.mu.RLock()
	notify := s.notify
	s.mu.RUnlock()
	if notify == nil {
		return
	}
	msg := map[string]any{"jsonrpc": "2.0", "method": method}
	if params != nil {
		msg["params"] = params
	}
	line, err := json.Marshal(msg)
	if err != nil {
		return
	}
	notify(line)
}

// writeStdout writes one line to stdout, serialized with notifications.
func (s *Server) writeStdout(line []byte) {
	s.stdoutMu.Lock()
	defer s.stdoutMu.Unlock()
	fmt.Fprintf(os.Stdout, "%s\n", line)
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

	if existing, ok := s.tools[name]; ok && existing.remote {
		fmt.Fprintf(os.Stderr, "[zeromcp] Local tool \"%s\" overrides remote\n", name)
	}

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

// Serve starts the stdio transport, the only transport ZeroMCP runs itself.
// To serve over HTTP, mount Registry() in your own HTTP server.
// Call this as the last line in main().
func (s *Server) Serve() {
	if err := checkTransports(s.cfg); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	s.logReadyCounts()
	s.serveStdio()
}

// ServeStdio starts only the stdio transport (convenience for simple use).
func (s *Server) ServeStdio() {
	s.logReadyCounts()
	s.serveStdio()
}

func (s *Server) serveStdio() {
	fmt.Fprintf(os.Stderr, "[zeromcp] stdio transport ready\n")

	s.mu.Lock()
	s.notify = s.writeStdout
	s.mu.Unlock()

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
		s.writeStdout(out)
	}

	os.Exit(0)
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
	execCtx := s.execCtx(rt)
	ch := make(chan executeResult, 1)
	go func() {
		v, e := rt.tool.Execute(args, execCtx)
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

// buildOpenAPISpec generates an OpenAPI 3.0 spec from all tools that have a Route field.
func (s *Server) buildOpenAPISpec() map[string]any {
	title := s.cfg.Title
	if title == "" {
		title = "ZeroMCP"
	}

	paths := map[string]any{}

	s.mu.RLock()
	names := make([]string, 0, len(s.tools))
	for name := range s.tools {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		rt := s.tools[name]
		if rt.tool.Route == nil {
			continue
		}
		route := rt.tool.Route
		method := strings.ToLower(route.Method)

		// Extract :param names from path
		pathParamNames := map[string]bool{}
		openAPIPath := regexp.MustCompile(`:(\w+)`).ReplaceAllStringFunc(route.Path, func(m string) string {
			paramName := m[1:]
			pathParamNames[paramName] = true
			return "{" + paramName + "}"
		})

		var operation map[string]any
		if method == "get" {
			params := []any{}
			for fieldName, fieldDef := range rt.tool.Input {
				paramSchema := fieldDefToOpenAPISchema(fieldDef)
				in := "query"
				required := true
				if pathParamNames[fieldName] {
					in = "path"
				}
				if f, ok := fieldDef.(InputField); ok && f.Optional {
					required = false
				}
				param := map[string]any{
					"name":     fieldName,
					"in":       in,
					"required": required,
					"schema":   paramSchema,
				}
				params = append(params, param)
			}
			operation = map[string]any{
				"operationId": name,
				"description": rt.tool.Description,
				"parameters":  params,
				"responses": map[string]any{
					"200": map[string]any{"description": "Success"},
					"500": map[string]any{"description": "Error"},
				},
			}
		} else {
			props := map[string]any{}
			required := []string{}
			for fieldName, fieldDef := range rt.tool.Input {
				if pathParamNames[fieldName] {
					continue
				}
				props[fieldName] = fieldDefToOpenAPISchema(fieldDef)
				if f, ok := fieldDef.(InputField); ok && f.Optional {
					continue
				}
				required = append(required, fieldName)
			}
			sort.Strings(required)
			bodySchema := map[string]any{
				"type":       "object",
				"properties": props,
			}
			if len(required) > 0 {
				bodySchema["required"] = required
			}
			operation = map[string]any{
				"operationId": name,
				"description": rt.tool.Description,
				"requestBody": map[string]any{
					"required": true,
					"content": map[string]any{
						"application/json": map[string]any{
							"schema": bodySchema,
						},
					},
				},
				"responses": map[string]any{
					"200": map[string]any{"description": "Success"},
					"500": map[string]any{"description": "Error"},
				},
			}
			if len(pathParamNames) > 0 {
				pathParams := make([]string, 0, len(pathParamNames))
				for paramName := range pathParamNames {
					pathParams = append(pathParams, paramName)
				}
				sort.Strings(pathParams)
				params := make([]any, 0, len(pathParams))
				for _, paramName := range pathParams {
					params = append(params, map[string]any{
						"name":     paramName,
						"in":       "path",
						"required": true,
						"schema":   map[string]any{"type": "string"},
					})
				}
				operation["parameters"] = params
			}
		}

		if _, exists := paths[openAPIPath]; !exists {
			paths[openAPIPath] = map[string]any{}
		}
		paths[openAPIPath].(map[string]any)[method] = operation
	}
	s.mu.RUnlock()

	return map[string]any{
		"openapi": "3.0.0",
		"info": map[string]any{
			"title":   title,
			"version": "0.5.0",
		},
		"paths": paths,
	}
}

// fieldDefToOpenAPISchema converts an Input field definition to an OpenAPI schema object.
func fieldDefToOpenAPISchema(fieldDef any) map[string]any {
	switch v := fieldDef.(type) {
	case string:
		return map[string]any{"type": v}
	case InputField:
		schema := map[string]any{"type": v.Type}
		if v.Description != "" {
			schema["description"] = v.Description
		}
		return schema
	default:
		return map[string]any{"type": "string"}
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
