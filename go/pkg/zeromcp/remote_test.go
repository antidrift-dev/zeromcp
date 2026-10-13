package zeromcp

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"sync"
	"testing"
)

type seenRequest struct {
	method        string
	authorization string
	contentType   string
}

// fakeUpstream is an MCP server over HTTP offering list_pages and get_page,
// ported from nodejs/test/handler-remote.test.js.
func fakeUpstream(t *testing.T) (*httptest.Server, func() []seenRequest) {
	t.Helper()
	var mu sync.Mutex
	var seen []seenRequest

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req map[string]any
		json.Unmarshal(body, &req)
		method, _ := req["method"].(string)

		mu.Lock()
		seen = append(seen, seenRequest{method, r.Header.Get("Authorization"), r.Header.Get("Content-Type")})
		mu.Unlock()

		resp := map[string]any{"jsonrpc": "2.0", "id": req["id"]}
		switch method {
		case "initialize":
			resp["result"] = map[string]any{"protocolVersion": "2025-03-26", "capabilities": map[string]any{}, "serverInfo": map[string]any{"name": "probeo", "version": "test"}}
		case "tools/list":
			resp["result"] = map[string]any{"tools": []any{
				map[string]any{"name": "list_pages", "description": "Lists pages.", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{"domain": map[string]any{"type": "string"}}, "required": []any{"domain"}}},
				map[string]any{"name": "get_page", "description": "Gets a page.", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{"url": map[string]any{"type": "string"}}, "required": []any{"url"}}},
			}}
		case "tools/call":
			pages, _ := json.Marshal(map[string]any{"pages": []any{}})
			resp["result"] = map[string]any{"content": []any{map[string]any{"type": "text", "text": string(pages)}}}
		default:
			resp["error"] = map[string]any{"message": "Unexpected method: " + method}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}))
	t.Cleanup(ts.Close)

	return ts, func() []seenRequest {
		mu.Lock()
		defer mu.Unlock()
		return append([]seenRequest(nil), seen...)
	}
}

func listedToolNames(t *testing.T, s *Server) []string {
	t.Helper()
	resp := s.HandleRequest(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
	result, _ := resp["result"].(map[string]any)
	tools, _ := result["tools"].([]any)
	names := []string{}
	for _, tool := range tools {
		names = append(names, tool.(map[string]any)["name"].(string))
	}
	sort.Strings(names)
	return names
}

func callContent(t *testing.T, s *Server, name string, args map[string]any) []any {
	t.Helper()
	resp := s.HandleRequest(map[string]any{
		"jsonrpc": "2.0", "id": 2, "method": "tools/call",
		"params": map[string]any{"name": name, "arguments": args},
	})
	result, _ := resp["result"].(map[string]any)
	content, _ := result["content"].([]any)
	return content
}

func TestRemoteComposesAllowlistedTools(t *testing.T) {
	ts, _ := fakeUpstream(t)
	s := NewServerWithConfig(Config{Remote: []RemoteServer{{Name: "probeo", URL: ts.URL, Tools: []string{"list_pages"}}}})

	if got := listedToolNames(t, s); !reflect.DeepEqual(got, []string{"probeo.list_pages"}) {
		t.Fatalf("expected [probeo.list_pages], got %v", got)
	}

	content := callContent(t, s, "probeo.list_pages", map[string]any{"domain": "example.com"})
	want := []any{map[string]any{"type": "text", "text": `{"pages":[]}`}}
	if !reflect.DeepEqual(content, want) {
		t.Errorf("expected %v, got %v", want, content)
	}
}

func TestRemoteSendsAuthAndContentType(t *testing.T) {
	t.Setenv("ZEROMCP_TEST_REMOTE_TOKEN", "tok-123")
	ts, seen := fakeUpstream(t)
	s := NewServerWithConfig(Config{Remote: []RemoteServer{{Name: "probeo", URL: ts.URL, Auth: "env:ZEROMCP_TEST_REMOTE_TOKEN"}}})
	callContent(t, s, "probeo.get_page", map[string]any{"url": "https://example.com"})

	reqs := seen()
	if len(reqs) != 3 {
		t.Fatalf("expected initialize, tools/list, tools/call; got %+v", reqs)
	}
	for i, method := range []string{"initialize", "tools/list", "tools/call"} {
		if reqs[i].method != method {
			t.Errorf("request %d: expected %s, got %s", i, method, reqs[i].method)
		}
		if reqs[i].authorization != "Bearer tok-123" {
			t.Errorf("%s: expected Bearer tok-123, got %q", method, reqs[i].authorization)
		}
		if reqs[i].contentType != "application/json" {
			t.Errorf("%s: expected application/json, got %q", method, reqs[i].contentType)
		}
	}
}

func TestRemoteLiteralAuth(t *testing.T) {
	ts, seen := fakeUpstream(t)
	NewServerWithConfig(Config{Remote: []RemoteServer{{Name: "probeo", URL: ts.URL, Auth: "literal-token"}}})
	for _, r := range seen() {
		if r.authorization != "Bearer literal-token" {
			t.Errorf("%s: expected Bearer literal-token, got %q", r.method, r.authorization)
		}
	}
}

func TestRemoteNoAuthHeaderWhenUnset(t *testing.T) {
	ts, seen := fakeUpstream(t)
	NewServerWithConfig(Config{Remote: []RemoteServer{{Name: "probeo", URL: ts.URL}}})
	for _, r := range seen() {
		if r.authorization != "" {
			t.Errorf("%s: expected no Authorization, got %q", r.method, r.authorization)
		}
	}
}

func TestRemoteFailedServersAreSkipped(t *testing.T) {
	ts, _ := fakeUpstream(t)
	failing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
	}))
	defer failing.Close()

	s := NewServerWithConfig(Config{Remote: []RemoteServer{
		{Name: "ftp", URL: "ftp://example.com/mcp"},
		{Name: "broken", URL: failing.URL},
		{Name: "probeo", URL: ts.URL},
	}})

	want := []string{"probeo.get_page", "probeo.list_pages"}
	if got := listedToolNames(t, s); !reflect.DeepEqual(got, want) {
		t.Errorf("expected %v, got %v", want, got)
	}
}

func TestConnectRemoteErrors(t *testing.T) {
	_, err := connectRemote(RemoteServer{Name: "ftp", URL: "ftp://example.com"})
	if err == nil || err.Error() != `Remote server "ftp" must have an HTTP/HTTPS URL, got: ftp://example.com` {
		t.Errorf("unexpected error: %v", err)
	}

	failing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(503)
	}))
	defer failing.Close()
	_, err = connectRemote(RemoteServer{Name: "down", URL: failing.URL})
	if err == nil || err.Error() != "HTTP 503" {
		t.Errorf("expected HTTP 503, got %v", err)
	}

	notJSON := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "not json")
	}))
	defer notJSON.Close()
	if _, err = connectRemote(RemoteServer{Name: "garbage", URL: notJSON.URL}); err == nil {
		t.Error("expected error for non-JSON body")
	}
}

func TestRemoteUnknownTypeFailsServer(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]any
		json.NewDecoder(r.Body).Decode(&req)
		resp := map[string]any{"jsonrpc": "2.0", "id": req["id"], "result": map[string]any{}}
		if req["method"] == "tools/list" {
			resp["result"] = map[string]any{"tools": []any{
				map[string]any{"name": "weird", "inputSchema": map[string]any{"properties": map[string]any{"x": map[string]any{"type": "integer"}}}},
			}}
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer ts.Close()

	if _, err := connectRemote(RemoteServer{Name: "weird", URL: ts.URL}); err == nil {
		t.Error("expected unknown type to fail the server")
	}
	s := NewServerWithConfig(Config{Remote: []RemoteServer{{Name: "weird", URL: ts.URL}}})
	if got := listedToolNames(t, s); len(got) != 0 {
		t.Errorf("expected no tools, got %v", got)
	}
}

func TestRemoteLocalToolOverrides(t *testing.T) {
	ts, _ := fakeUpstream(t)
	s := NewServerWithConfig(Config{Remote: []RemoteServer{{Name: "probeo", URL: ts.URL, Tools: []string{"list_pages"}}}})
	s.Tool("probeo.list_pages", Tool{
		Input: Input{},
		Execute: func(args map[string]any, ctx *Ctx) (any, error) {
			return "local", nil
		},
	})

	content := callContent(t, s, "probeo.list_pages", map[string]any{})
	if len(content) != 1 || content[0].(map[string]any)["text"] != "local" {
		t.Errorf("expected local tool result, got %v", content)
	}
}

func TestRemoteAllowlistNilExposesAll(t *testing.T) {
	ts, _ := fakeUpstream(t)
	s := NewServerWithConfig(Config{Remote: []RemoteServer{{Name: "probeo", URL: ts.URL}}})
	want := []string{"probeo.get_page", "probeo.list_pages"}
	if got := listedToolNames(t, s); !reflect.DeepEqual(got, want) {
		t.Errorf("expected %v, got %v", want, got)
	}
}

func TestRemoteAllowlistEmptyExposesNone(t *testing.T) {
	ts, _ := fakeUpstream(t)
	s := NewServerWithConfig(Config{Remote: []RemoteServer{{Name: "probeo", URL: ts.URL, Tools: []string{}}}})
	if got := listedToolNames(t, s); len(got) != 0 {
		t.Errorf("expected no tools, got %v", got)
	}
}

func TestRemoteExecuteReturnsResultWhenNoText(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]any
		json.NewDecoder(r.Body).Decode(&req)
		resp := map[string]any{"jsonrpc": "2.0", "id": req["id"], "result": map[string]any{}}
		switch req["method"] {
		case "tools/list":
			resp["result"] = map[string]any{"tools": []any{map[string]any{"name": "empty"}}}
		case "tools/call":
			resp["result"] = map[string]any{"content": []any{map[string]any{"type": "text", "text": ""}}, "extra": 1}
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer ts.Close()

	s := NewServerWithConfig(Config{Remote: []RemoteServer{{Name: "up", URL: ts.URL}}})
	content := callContent(t, s, "up.empty", map[string]any{})
	if len(content) != 1 {
		t.Fatalf("unexpected content %v", content)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(content[0].(map[string]any)["text"].(string)), &got); err != nil {
		t.Fatalf("expected JSON of the whole result, got %v", content)
	}
	if got["extra"] != float64(1) {
		t.Errorf("expected whole result returned, got %v", got)
	}
}

func TestSchemaToInput(t *testing.T) {
	input := schemaToInput(map[string]any{
		"type": "object",
		"properties": map[string]any{
			"untyped": map[string]any{},
			"req":     map[string]any{"type": "number"},
			"reqDesc": map[string]any{"type": "string", "description": "has desc"},
			"opt":     map[string]any{"type": "boolean"},
			"optDesc": map[string]any{"type": "array", "description": "opt desc"},
		},
		"required": []any{"untyped", "req", "reqDesc"},
	})

	want := Input{
		"untyped": "string",
		"req":     "number",
		"reqDesc": InputField{Type: "string", Description: "has desc"},
		"opt":     InputField{Type: "boolean", Optional: true},
		"optDesc": InputField{Type: "array", Description: "opt desc", Optional: true},
	}
	if !reflect.DeepEqual(input, want) {
		t.Errorf("got %#v\nwant %#v", input, want)
	}

	if got := schemaToInput(nil); len(got) != 0 {
		t.Errorf("expected empty input for nil schema, got %v", got)
	}
	if got := schemaToInput(map[string]any{"type": "object"}); len(got) != 0 {
		t.Errorf("expected empty input without properties, got %v", got)
	}
}
