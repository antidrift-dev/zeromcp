# ZeroMCP &mdash; Ruby

Drop a `.rb` file in a folder, get a sandboxed MCP server. Stdio out of the box, zero dependencies.

## Getting started

```ruby
# tools/hello.rb — this is a complete MCP server
tool description: "Say hello to someone",
     input: { name: "string" }

execute do |args, ctx|
  "Hello, #{args['name']}!"
end
```

```sh
ruby -I lib bin/zeromcp serve ./tools
```

That's it. Stdio works immediately. Drop another `.rb` file to add another tool. Delete a file to remove one.

## vs. the official SDK

The official Ruby SDK requires server setup, transport configuration, and explicit tool registration. ZeroMCP is file-based &mdash; each tool is its own file, discovered automatically. Zero external dependencies.

In benchmarks, ZeroMCP Ruby handles 15,327 requests/second over stdio versus the official SDK's 12,935 &mdash; 1.2x faster with 50% less memory (12 MB vs 24 MB). Over HTTP (Rack+Puma), ZeroMCP serves 3,217 rps at 26 MB versus the official SDK's 2,163 rps at 49&ndash;56 MB. The official SDK crashed on binary garbage input and corrupted responses under slow tools in chaos testing. ZeroMCP survived 22/22 attacks.

The official SDK has **no sandbox**. ZeroMCP lets tools declare network, filesystem, and exec permissions.

Ruby passes all 10 conformance suites.

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer. You bring your own framework; ZeroMCP gives you a `handle_request` method that takes a Hash and returns a Hash (or `nil` for notifications).

```ruby
# response = server.handle_request(request)
```

**Sinatra**

```ruby
require 'sinatra'
require 'json'

post '/mcp' do
  request_body = JSON.parse(request.body.read)
  response = server.handle_request(request_body)

  if response.nil?
    status 204
  else
    content_type :json
    response.to_json
  end
end
```

## Requirements

- Ruby 3.0+
- No external dependencies

## Install

```sh
gem build zeromcp.gemspec
gem install zeromcp-0.1.0.gem
```

## Sandbox

```ruby
tool description: "Fetch from our API",
     input: { url: "string" },
     permissions: {
       network: ["api.example.com", "*.internal.dev"],
       fs: false,
       exec: false
     }

execute do |args, ctx|
  # ...
end
```

## Directory structure

Tools are discovered recursively. Subdirectory names become namespace prefixes:

```
tools/
  hello.rb          -> tool "hello"
  math/
    add.rb          -> tool "math_add"
```

## Testing

```sh
ruby -I lib -I test -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'
```
