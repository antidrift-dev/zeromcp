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
