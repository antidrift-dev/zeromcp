package zeromcp

import (
	"encoding/json"
	"testing"
)

func TestRegistryRoutesOnlyIncludesRoutedTools(t *testing.T) {
	s := NewServer()
	s.Tool("greet", Tool{
		Description: "Greet someone",
		Input:       Input{"name": "string"},
		Route:       &RouteConfig{Method: "GET", Path: "/greet/:name"},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			return "hi " + args["name"].(string), nil
		},
	})
	s.Tool("hidden", Tool{
		Description: "No route",
		Input:       Input{},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			return nil, nil
		},
	})

	reg := s.Registry()
	if len(reg.Routes) != 1 {
		t.Fatalf("expected 1 route, got %d", len(reg.Routes))
	}
	if reg.Routes[0].Name != "greet" {
		t.Errorf("expected route for greet, got %s", reg.Routes[0].Name)
	}
	if reg.Routes[0].Route.Method != "GET" || reg.Routes[0].Route.Path != "/greet/:name" {
		t.Errorf("unexpected route metadata: %+v", reg.Routes[0].Route)
	}
}

func TestRegistryRoutesAreSortedByName(t *testing.T) {
	s := NewServer()
	for _, name := range []string{"charlie", "alpha", "bravo"} {
		s.Tool(name, Tool{
			Description: name,
			Input:       Input{},
			Route:       &RouteConfig{Method: "GET", Path: "/" + name},
			Execute: func(args map[string]any, ctx *Ctx) (any, error) {
				return nil, nil
			},
		})
	}

	reg := s.Registry()
	if len(reg.Routes) != 3 {
		t.Fatalf("expected 3 routes, got %d", len(reg.Routes))
	}
	got := []string{reg.Routes[0].Name, reg.Routes[1].Name, reg.Routes[2].Name}
	want := []string{"alpha", "bravo", "charlie"}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("expected sorted order %v, got %v", want, got)
		}
	}
}

func TestRegistryInvokeCallsToolWithResolvedContext(t *testing.T) {
	s := NewServer()
	s.Tool("greet", Tool{
		Description: "Greet someone",
		Input:       Input{"name": "string"},
		Route:       &RouteConfig{Method: "GET", Path: "/greet/:name"},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			if ctx == nil {
				t.Error("expected non-nil ctx")
			}
			return "hi " + args["name"].(string), nil
		},
	})

	reg := s.Registry()
	result, err := reg.Routes[0].Invoke(map[string]any{"name": "Ada"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != "hi Ada" {
		t.Errorf("expected 'hi Ada', got %v", result)
	}
}

func TestRegistryOpenAPIMatchesBuildOpenAPISpec(t *testing.T) {
	s := NewServer()
	s.Tool("greet", Tool{
		Description: "Greet someone",
		Input:       Input{"name": "string"},
		Route:       &RouteConfig{Method: "GET", Path: "/greet/:name"},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			return nil, nil
		},
	})

	reg := s.Registry()
	direct := s.buildOpenAPISpec()

	regJSON, err := json.Marshal(reg.OpenAPI)
	if err != nil {
		t.Fatalf("marshal reg.OpenAPI: %v", err)
	}
	directJSON, err := json.Marshal(direct)
	if err != nil {
		t.Fatalf("marshal direct spec: %v", err)
	}
	if string(regJSON) != string(directJSON) {
		t.Errorf("expected Registry().OpenAPI to match buildOpenAPISpec() output\ngot:  %s\nwant: %s", regJSON, directJSON)
	}
}

func TestRegistryMCPDispatchesJSONRPC(t *testing.T) {
	s := NewServer()
	s.Tool("greet", Tool{
		Description: "Greet someone",
		Input:       Input{"name": "string"},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			return "hi " + args["name"].(string), nil
		},
	})

	reg := s.Registry()
	req := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	respBytes := reg.MCP(req)

	var resp map[string]any
	if err := json.Unmarshal(respBytes, &resp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatal("expected result object")
	}
	tools, ok := result["tools"].([]any)
	if !ok || len(tools) != 1 {
		t.Fatalf("expected 1 tool, got %v", result["tools"])
	}
}

func TestRegistryEmptyWhenNoRoutedTools(t *testing.T) {
	s := NewServer()
	s.Tool("noroute", Tool{
		Description: "No route",
		Input:       Input{},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			return nil, nil
		},
	})

	reg := s.Registry()
	if len(reg.Routes) != 0 {
		t.Errorf("expected 0 routes, got %d", len(reg.Routes))
	}
}
