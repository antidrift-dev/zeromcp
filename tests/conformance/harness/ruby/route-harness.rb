# frozen_string_literal: true

# Route + OpenAPI conformance harness for Ruby.
#
# ZeroMCP ships no HTTP server, so this test-only script mounts
# ZeroMcp.create_registry (routes, openapi, mcp) on WEBrick, the way a user
# would mount it in their own server. WEBrick is a dependency of this harness
# only, not of the gem.
#
# Usage: ruby -I ruby/lib tests/conformance/harness/ruby/route-harness.rb [port]

require 'zeromcp'
require 'webrick'
require 'json'

root = File.expand_path('../../../..', __dir__)
port = (ARGV[0] || 14252).to_i

config = ZeroMcp::Config.new('tools' => File.join(root, 'tests/conformance/route-tools'))
tools = ZeroMcp::Scanner.new(config).scan
registry = ZeroMcp.create_registry(tools, config: config)

DOCS_HTML = <<~HTML
  <!DOCTYPE html>
  <html>
  <head>
    <title>ZeroMCP API</title>
    <meta charset="utf-8"/>
    <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
  </head>
  <body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
  <script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>
  </body>
  </html>
HTML

# Compile each route's :param path to a regex once.
compiled = registry.routes.map do |route|
  names = []
  pattern = route.path.gsub(/:([A-Za-z_][A-Za-z0-9_]*)/) { names << Regexp.last_match(1); '([^/]+)' }
  [route, /\A#{pattern}\z/, names]
end

def json(res, status, body)
  res.status = status
  res.content_type = 'application/json'
  res.body = JSON.generate(body)
end

server = WEBrick::HTTPServer.new(Port: port, BindAddress: '0.0.0.0',
                                 Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN), AccessLog: [])

server.mount_proc('/') do |req, res|
  case [req.request_method, req.path]
  when ['GET', '/health']
    json(res, 200, { 'ok' => true })
  when ['GET', '/openapi.json']
    json(res, 200, registry.openapi)
  when ['GET', '/docs']
    res.content_type = 'text/html'
    res.body = DOCS_HTML
  when ['POST', '/mcp']
    begin
      response = registry.mcp.call(JSON.parse(req.body || '{}'))
      json(res, 200, response || {})
    rescue JSON::ParserError
      json(res, 400, { 'error' => 'Invalid JSON' })
    end
  else
    match = nil
    compiled.each do |route, regex, names|
      next unless route.method == req.request_method
      m = regex.match(req.path)
      next unless m
      match = [route, names.each_with_index.to_h { |n, i| [n, m[i + 1]] }]
      break
    end

    if match.nil?
      json(res, 404, { 'ok' => false, 'error' => 'Not found' })
    else
      route, path_params = match
      args = if req.request_method == 'GET'
               WEBrick::HTTPUtils.parse_query(req.query_string || '')
             else
               begin
                 req.body && !req.body.empty? ? JSON.parse(req.body) : {}
               rescue JSON::ParserError
                 {}
               end
             end
      begin
        result = route.tool.call(args.merge(path_params), registry.context_for(route.tool))
        json(res, 200, { 'ok' => true, 'result' => result })
      rescue StandardError => e
        json(res, 500, { 'ok' => false, 'error' => e.message })
      end
    end
  end
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }
$stderr.puts "[route-harness] Ruby listening on #{port}"
server.start
