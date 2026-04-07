package zeromcp

import (
	"encoding/json"
	"fmt"
	"testing"
)

func TestHandleInitialize(t *testing.T) {
	s := NewServer()
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "initialize",
	})

	if resp == nil {
		t.Fatal("expected response")
	}
	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error)
	}

	result, ok := resp.Result.(map[string]any)
	if !ok {
		t.Fatal("expected result map")
	}
	if result["protocolVersion"] != protocolVersion {
		t.Errorf("expected protocol version %s", protocolVersion)
	}
}

func TestHandlePing(t *testing.T) {
	s := NewServer()
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "ping",
	})
	if resp == nil {
		t.Fatal("expected response")
	}
	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error)
	}
}

func TestHandleToolsList(t *testing.T) {
	s := NewServer()
	s.Tool("hello", Tool{
		Description: "Say hello",
		Input:       Input{"name": "string"},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			return fmt.Sprintf("Hello, %s!", args["name"]), nil
		},
	})

	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "tools/list",
	})

	if resp == nil {
		t.Fatal("expected response")
	}
	result, ok := resp.Result.(map[string]any)
	if !ok {
		t.Fatal("expected result map")
	}
	tools, ok := result["tools"].([]map[string]any)
	if !ok {
		t.Fatal("expected tools array")
	}
	if len(tools) != 1 {
		t.Fatalf("expected 1 tool, got %d", len(tools))
	}
	if tools[0]["name"] != "hello" {
		t.Errorf("expected tool name 'hello', got %v", tools[0]["name"])
	}
}

func TestHandleToolsCall(t *testing.T) {
	s := NewServer()
	s.Tool("hello", Tool{
		Description: "Say hello",
		Input:       Input{"name": "string"},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			return fmt.Sprintf("Hello, %s!", args["name"]), nil
		},
	})

	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "tools/call",
		Params: map[string]any{
			"name":      "hello",
			"arguments": map[string]any{"name": "World"},
		},
	})

	if resp == nil {
		t.Fatal("expected response")
	}
	result, ok := resp.Result.(map[string]any)
	if !ok {
		t.Fatal("expected result map")
	}
	content, ok := result["content"].([]map[string]any)
	if !ok {
		t.Fatal("expected content array")
	}
	if content[0]["text"] != "Hello, World!" {
		t.Errorf("expected 'Hello, World!', got %v", content[0]["text"])
	}
}

func TestHandleToolsCallUnknown(t *testing.T) {
	s := NewServer()
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "tools/call",
		Params:  map[string]any{"name": "nonexistent", "arguments": map[string]any{}},
	})

	result, ok := resp.Result.(map[string]any)
	if !ok {
		t.Fatal("expected result map")
	}
	if result["isError"] != true {
		t.Error("expected isError=true")
	}
}

func TestHandleToolsCallValidation(t *testing.T) {
	s := NewServer()
	s.Tool("add", Tool{
		Description: "Add numbers",
		Input:       Input{"a": "number", "b": "number"},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			return nil, nil
		},
	})

	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "tools/call",
		Params:  map[string]any{"name": "add", "arguments": map[string]any{}},
	})

	result, ok := resp.Result.(map[string]any)
	if !ok {
		t.Fatal("expected result map")
	}
	if result["isError"] != true {
		t.Error("expected validation error")
	}
}

func TestHandleNotification(t *testing.T) {
	s := NewServer()
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		Method:  "notifications/initialized",
	})
	if resp != nil {
		t.Error("expected nil response for notification")
	}
}

func TestHandleUnknownMethod(t *testing.T) {
	s := NewServer()
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "unknown/method",
	})
	if resp.Error == nil {
		t.Error("expected error for unknown method")
	}
	if resp.Error.Code != -32601 {
		t.Errorf("expected code -32601, got %d", resp.Error.Code)
	}
}

// --- Resource tests ---

func TestHandleResourcesList(t *testing.T) {
	s := NewServer()
	s.Resource("status", ResourceDef{
		URI:         "app://status",
		Description: "App status",
		MimeType:    "application/json",
		Read: func() (string, error) {
			return `{"ok":true}`, nil
		},
	})

	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "resources/list",
	})
	if resp == nil || resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp)
	}
	result := resp.Result.(map[string]any)
	resources := result["resources"].([]map[string]any)
	if len(resources) != 1 {
		t.Fatalf("expected 1 resource, got %d", len(resources))
	}
	if resources[0]["uri"] != "app://status" {
		t.Errorf("expected uri 'app://status', got %v", resources[0]["uri"])
	}
}

func TestHandleResourcesRead(t *testing.T) {
	s := NewServer()
	s.Resource("status", ResourceDef{
		URI:         "app://status",
		Description: "App status",
		MimeType:    "application/json",
		Read: func() (string, error) {
			return `{"ok":true}`, nil
		},
	})

	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "resources/read",
		Params:  map[string]any{"uri": "app://status"},
	})
	if resp == nil || resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp)
	}
	result := resp.Result.(map[string]any)
	contents := result["contents"].([]map[string]any)
	if contents[0]["text"] != `{"ok":true}` {
		t.Errorf("unexpected text: %v", contents[0]["text"])
	}
}

func TestHandleResourcesReadNotFound(t *testing.T) {
	s := NewServer()
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "resources/read",
		Params:  map[string]any{"uri": "app://nope"},
	})
	if resp.Error == nil {
		t.Error("expected error for missing resource")
	}
	if resp.Error.Code != -32002 {
		t.Errorf("expected code -32002, got %d", resp.Error.Code)
	}
}

func TestHandleResourceTemplate(t *testing.T) {
	s := NewServer()
	s.ResourceTemplate("user", ResourceTemplateDef{
		UriTemplate: "app://users/{id}",
		Description: "User by ID",
		MimeType:    "application/json",
		Read: func(params map[string]string) (string, error) {
			return fmt.Sprintf(`{"id":"%s"}`, params["id"]), nil
		},
	})

	// templates/list
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "resources/templates/list",
	})
	if resp == nil || resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp)
	}
	result := resp.Result.(map[string]any)
	templates := result["resourceTemplates"].([]map[string]any)
	if len(templates) != 1 {
		t.Fatalf("expected 1 template, got %d", len(templates))
	}

	// resources/read with template match
	resp = s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(2),
		Method:  "resources/read",
		Params:  map[string]any{"uri": "app://users/42"},
	})
	if resp == nil || resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp)
	}
	result = resp.Result.(map[string]any)
	contents := result["contents"].([]map[string]any)
	if contents[0]["text"] != `{"id":"42"}` {
		t.Errorf("unexpected text: %v", contents[0]["text"])
	}
}

func TestHandleResourcesSubscribe(t *testing.T) {
	s := NewServer()
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "resources/subscribe",
		Params:  map[string]any{"uri": "app://status"},
	})
	if resp == nil || resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp)
	}
	if !s.subscriptions["app://status"] {
		t.Error("expected subscription to be recorded")
	}
}

// --- Prompt tests ---

func TestHandlePromptsList(t *testing.T) {
	s := NewServer()
	s.Prompt("greet", PromptDef{
		Description: "Greeting prompt",
		Arguments: []PromptArgument{
			{Name: "name", Description: "Who to greet", Required: true},
		},
		Render: func(args map[string]any) ([]PromptMessage, error) {
			return []PromptMessage{{Role: "user", Content: map[string]any{"type": "text", "text": fmt.Sprintf("Hello %s", args["name"])}}}, nil
		},
	})

	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "prompts/list",
	})
	if resp == nil || resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp)
	}
	result := resp.Result.(map[string]any)
	prompts := result["prompts"].([]map[string]any)
	if len(prompts) != 1 {
		t.Fatalf("expected 1 prompt, got %d", len(prompts))
	}
	if prompts[0]["name"] != "greet" {
		t.Errorf("expected prompt name 'greet', got %v", prompts[0]["name"])
	}
}

func TestHandlePromptsGet(t *testing.T) {
	s := NewServer()
	s.Prompt("greet", PromptDef{
		Description: "Greeting prompt",
		Render: func(args map[string]any) ([]PromptMessage, error) {
			name, _ := args["name"].(string)
			return []PromptMessage{{Role: "user", Content: map[string]any{"type": "text", "text": "Hello " + name}}}, nil
		},
	})

	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "prompts/get",
		Params:  map[string]any{"name": "greet", "arguments": map[string]any{"name": "World"}},
	})
	if resp == nil || resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp)
	}
	// Verify messages are returned
	result := resp.Result.(map[string]any)
	messages := result["messages"].([]PromptMessage)
	if len(messages) != 1 {
		t.Fatalf("expected 1 message, got %d", len(messages))
	}
	if messages[0].Role != "user" {
		t.Errorf("expected role 'user', got %v", messages[0].Role)
	}
}

func TestHandlePromptsGetNotFound(t *testing.T) {
	s := NewServer()
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "prompts/get",
		Params:  map[string]any{"name": "nope"},
	})
	if resp.Error == nil {
		t.Error("expected error for missing prompt")
	}
	if resp.Error.Code != -32002 {
		t.Errorf("expected code -32002, got %d", resp.Error.Code)
	}
}

// --- Passthrough tests ---

func TestHandleLoggingSetLevel(t *testing.T) {
	s := NewServer()
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "logging/setLevel",
		Params:  map[string]any{"level": "debug"},
	})
	if resp == nil || resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp)
	}
	if s.logLevel != "debug" {
		t.Errorf("expected logLevel 'debug', got %s", s.logLevel)
	}
}

func TestHandleCompletionComplete(t *testing.T) {
	s := NewServer()
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "completion/complete",
	})
	if resp == nil || resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp)
	}
	result := resp.Result.(map[string]any)
	completion := result["completion"].(map[string]any)
	if completion["values"] == nil {
		t.Error("expected values array")
	}
}

// --- Initialize capabilities ---

func TestInitializeCapabilitiesWithResources(t *testing.T) {
	s := NewServer()
	s.Resource("r", ResourceDef{URI: "app://r", Read: func() (string, error) { return "", nil }})

	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "initialize",
	})
	result := resp.Result.(map[string]any)
	caps := result["capabilities"].(map[string]any)
	if caps["resources"] == nil {
		t.Error("expected resources capability")
	}
	if caps["logging"] == nil {
		t.Error("expected logging capability")
	}
}

func TestInitializeCapabilitiesWithPrompts(t *testing.T) {
	s := NewServer()
	s.Prompt("p", PromptDef{Render: func(args map[string]any) ([]PromptMessage, error) { return nil, nil }})

	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "initialize",
	})
	result := resp.Result.(map[string]any)
	caps := result["capabilities"].(map[string]any)
	if caps["prompts"] == nil {
		t.Error("expected prompts capability")
	}
}

// --- Pagination ---

func TestPagination(t *testing.T) {
	s := NewServerWithConfig(Config{PageSize: 2})
	s.Tool("a", Tool{Description: "A", Input: Input{}, Execute: func(args map[string]any, ctx *Ctx) (any, error) { return "a", nil }})
	s.Tool("b", Tool{Description: "B", Input: Input{}, Execute: func(args map[string]any, ctx *Ctx) (any, error) { return "b", nil }})
	s.Tool("c", Tool{Description: "C", Input: Input{}, Execute: func(args map[string]any, ctx *Ctx) (any, error) { return "c", nil }})

	// First page
	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "tools/list",
	})
	result := resp.Result.(map[string]any)
	tools := result["tools"].([]map[string]any)
	if len(tools) != 2 {
		t.Fatalf("expected 2 tools on first page, got %d", len(tools))
	}
	nextCursor, ok := result["nextCursor"].(string)
	if !ok || nextCursor == "" {
		t.Fatal("expected nextCursor")
	}

	// Second page
	resp = s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(2),
		Method:  "tools/list",
		Params:  map[string]any{"cursor": nextCursor},
	})
	result = resp.Result.(map[string]any)
	tools = result["tools"].([]map[string]any)
	if len(tools) != 1 {
		t.Fatalf("expected 1 tool on second page, got %d", len(tools))
	}
	if result["nextCursor"] != nil {
		t.Error("expected no nextCursor on last page")
	}
}

// --- Template matching ---

func TestMatchTemplate(t *testing.T) {
	params := matchTemplate("app://users/{id}", "app://users/42")
	if params == nil {
		t.Fatal("expected match")
	}
	if params["id"] != "42" {
		t.Errorf("expected id=42, got %v", params["id"])
	}

	// No match
	params = matchTemplate("app://users/{id}", "app://posts/1")
	if params != nil {
		t.Error("expected no match")
	}
}

func TestResponseSerializesToJSON(t *testing.T) {
	s := NewServer()
	s.Tool("test", Tool{
		Description: "Test",
		Input:       Input{},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			return "ok", nil
		},
	})

	resp := s.handleRequest(jsonRPCRequest{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "tools/call",
		Params:  map[string]any{"name": "test", "arguments": map[string]any{}},
	})

	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("failed to marshal response: %v", err)
	}

	var parsed map[string]any
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("failed to parse response JSON: %v", err)
	}
	if parsed["jsonrpc"] != "2.0" {
		t.Errorf("expected jsonrpc 2.0 in output")
	}
}
