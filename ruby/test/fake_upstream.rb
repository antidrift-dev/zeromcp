# frozen_string_literal: true

# Test-only fake remote MCP server on WEBrick (webrick is a test dependency,
# not a gem dependency). Answers initialize / tools/list (two tools) /
# tools/call like nodejs/test/handler-remote.test.js.

require 'webrick'
require 'json'

class FakeUpstream
  attr_reader :requests

  # status: HTTP status to answer every request with (non-2xx simulates a broken upstream).
  def initialize(status: 200)
    @status = status
    @requests = []
    @server = WEBrick::HTTPServer.new(
      Port: 0, BindAddress: '127.0.0.1',
      Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    @server.mount_proc('/') { |req, res| handle(req, res) }
    @thread = Thread.new { @server.start }
  end

  def url
    "http://127.0.0.1:#{@server.config[:Port]}/mcp"
  end

  def stop
    @server.shutdown
    @thread.join(2)
  end

  def calls
    @requests.select { |r| r[:body]['method'] == 'tools/call' }
  end

  private

  def handle(req, res)
    body = JSON.parse(req.body || '{}')
    @requests << { body: body, authorization: req['Authorization'] }
    res.status = @status
    res.content_type = 'application/json'
    res.body = JSON.generate({ 'jsonrpc' => '2.0', 'id' => body['id'] }.merge(response_for(body)))
  end

  def response_for(request)
    case request['method']
    when 'initialize'
      { 'result' => { 'protocolVersion' => '2025-03-26', 'capabilities' => {}, 'serverInfo' => { 'name' => 'probeo', 'version' => 'test' } } }
    when 'tools/list'
      { 'result' => { 'tools' => [
        { 'name' => 'list_pages', 'description' => 'Lists pages.',
          'inputSchema' => { 'type' => 'object', 'properties' => { 'domain' => { 'type' => 'string' } }, 'required' => ['domain'] } },
        { 'name' => 'get_page', 'description' => 'Gets a page.',
          'inputSchema' => { 'type' => 'object', 'properties' => { 'url' => { 'type' => 'string' } }, 'required' => ['url'] } }
      ] } }
    when 'tools/call'
      args = request.dig('params', 'arguments') || {}
      { 'result' => { 'content' => [{ 'type' => 'text', 'text' => JSON.generate({ 'pages' => [], 'tool' => request.dig('params', 'name'), 'args' => args }) }] } }
    else
      { 'error' => { 'message' => "Unexpected method: #{request['method']}" } }
    end
  end
end
