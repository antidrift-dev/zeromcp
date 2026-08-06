package zeromcp

import "sort"

// RouteDefinition pairs a tool that has a Route with everything an external
// HTTP framework needs to mount it: identity, route metadata, the input
// shape, and a ready-to-call invoke function.
type RouteDefinition struct {
	Name        string
	Route       RouteConfig // the tool's Route, dereferenced (never nil here)
	Description string
	Input       Input
	Invoke      func(args map[string]any) (any, error)
}

// Registry is a framework-neutral view over a Server's registered tools:
// route metadata for mounting on an external HTTP framework, a precomputed
// OpenAPI document, and a JSON-RPC handler for MCP. It starts no transport
// and binds no port.
type Registry struct {
	Routes  []RouteDefinition
	OpenAPI map[string]any
	MCP     func(raw []byte) []byte
}

// Registry builds a framework-neutral Registry snapshot from the tools
// currently registered on s via Tool(). Call it after all Tool() (and,
// if used, Resource()/Prompt()) registrations are done — the same point
// in program order you'd otherwise call Serve(). Registry does not start
// stdio or HTTP transports; it's an alternative to Serve() for embedding
// ZeroMCP's tools into your own HTTP framework instead of using the
// built-in server.
func (s *Server) Registry() *Registry {
	s.mu.RLock()
	defer s.mu.RUnlock()

	names := make([]string, 0, len(s.tools))
	for name := range s.tools {
		names = append(names, name)
	}
	sort.Strings(names)

	routes := make([]RouteDefinition, 0, len(names))
	for _, name := range names {
		rt := s.tools[name]
		if rt.tool.Route == nil {
			continue
		}
		routes = append(routes, RouteDefinition{
			Name:        name,
			Route:       *rt.tool.Route,
			Description: rt.tool.Description,
			Input:       rt.tool.Input,
			Invoke: func(args map[string]any) (any, error) {
				return rt.tool.Execute(args, rt.ctx)
			},
		})
	}

	return &Registry{
		Routes:  routes,
		OpenAPI: s.buildOpenAPISpec(),
		MCP:     s.HandleRequestBytes,
	}
}
