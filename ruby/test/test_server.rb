# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/zeromcp/server'

class TestServer < Minitest::Test
  def setup
    fixtures = File.join(__dir__, 'fixtures')
    @config = ZeroMcp::Config.new(
      'tools' => File.join(__dir__, '..', 'tools'),
      'resources' => File.join(fixtures, 'resources'),
      'prompts' => File.join(fixtures, 'prompts'),
      'page_size' => 0
    )
    @server = ZeroMcp::Server.new(@config)
    @server.load_tools
  end

  # --- initialize ---

  def test_handle_initialize
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 1, 'method' => 'initialize', 'params' => {}
    })
    assert_equal '2.0', resp['jsonrpc']
    assert_equal 1, resp['id']
    result = resp['result']
    assert_equal '2024-11-05', result['protocolVersion']
    assert result['capabilities'].key?('tools')
    assert result['capabilities'].key?('resources')
    assert result['capabilities'].key?('prompts')
    assert result['capabilities'].key?('logging')
    assert_equal 'zeromcp', result['serverInfo']['name']
  end

  # --- ping ---

  def test_handle_ping
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 2, 'method' => 'ping'
    })
    assert_equal({}, resp['result'])
  end

  # --- tools/list ---

  def test_tools_list
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 3, 'method' => 'tools/list', 'params' => {}
    })
    tools = resp['result']['tools']
    refute_nil tools
    names = tools.map { |t| t['name'] }
    assert_includes names, 'hello'
    assert_includes names, 'add'
  end

  def test_tools_list_has_schema
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 4, 'method' => 'tools/list', 'params' => {}
    })
    hello = resp['result']['tools'].find { |t| t['name'] == 'hello' }
    assert_equal 'object', hello['inputSchema']['type']
    assert hello['inputSchema']['properties'].key?('name')
  end

  # --- tools/call ---

  def test_tools_call_hello
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 5, 'method' => 'tools/call',
      'params' => { 'name' => 'hello', 'arguments' => { 'name' => 'World' } }
    })
    content = resp['result']['content']
    assert_equal 1, content.length
    assert_equal 'text', content[0]['type']
    assert_equal 'Hello, World!', content[0]['text']
  end

  def test_tools_call_add
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 6, 'method' => 'tools/call',
      'params' => { 'name' => 'add', 'arguments' => { 'a' => 3, 'b' => 4 } }
    })
    text = resp['result']['content'][0]['text']
    parsed = JSON.parse(text)
    assert_equal 7, parsed['sum']
  end

  def test_tools_call_unknown_tool
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 7, 'method' => 'tools/call',
      'params' => { 'name' => 'nonexistent', 'arguments' => {} }
    })
    assert_equal true, resp['result']['isError']
    assert_match(/Unknown tool/, resp['result']['content'][0]['text'])
  end

  def test_tools_call_validation_error
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 8, 'method' => 'tools/call',
      'params' => { 'name' => 'hello', 'arguments' => {} }
    })
    assert_equal true, resp['result']['isError']
    assert_match(/Validation errors/, resp['result']['content'][0]['text'])
  end

  # --- resources/list ---

  def test_resources_list
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 10, 'method' => 'resources/list', 'params' => {}
    })
    resources = resp['result']['resources']
    refute_nil resources
    names = resources.map { |r| r['name'] }
    assert_includes names, 'data'
    assert_includes names, 'notes'
    assert_includes names, 'status'
  end

  def test_resources_list_has_mime_type
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 11, 'method' => 'resources/list', 'params' => {}
    })
    data_res = resp['result']['resources'].find { |r| r['name'] == 'data' }
    assert_equal 'application/json', data_res['mimeType']
  end

  # --- resources/read ---

  def test_resources_read_static
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 12, 'method' => 'resources/read',
      'params' => { 'uri' => 'resource:///notes.txt' }
    })
    contents = resp['result']['contents']
    assert_equal 1, contents.length
    assert_match(/Hello from a static text resource/, contents[0]['text'])
    assert_equal 'text/plain', contents[0]['mimeType']
  end

  def test_resources_read_dynamic
    # Find the URI for status resource
    list_resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 13, 'method' => 'resources/list', 'params' => {}
    })
    status_res = list_resp['result']['resources'].find { |r| r['name'] == 'status' }
    uri = status_res['uri']

    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 14, 'method' => 'resources/read',
      'params' => { 'uri' => uri }
    })
    parsed = JSON.parse(resp['result']['contents'][0]['text'])
    assert_equal 'ok', parsed['status']
  end

  def test_resources_read_template
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 15, 'method' => 'resources/read',
      'params' => { 'uri' => 'user:///99' }
    })
    contents = resp['result']['contents']
    parsed = JSON.parse(contents[0]['text'])
    assert_equal '99', parsed['id']
    assert_equal 'User 99', parsed['name']
  end

  def test_resources_read_not_found
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 16, 'method' => 'resources/read',
      'params' => { 'uri' => 'resource:///nonexistent' }
    })
    assert resp['error']
    assert_equal(-32002, resp['error']['code'])
  end

  # --- resources/templates/list ---

  def test_resources_templates_list
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 17, 'method' => 'resources/templates/list', 'params' => {}
    })
    templates = resp['result']['resourceTemplates']
    refute_nil templates
    assert templates.length >= 1
    user_tmpl = templates.find { |t| t['name'] == 'user' }
    refute_nil user_tmpl
    assert_equal 'user:///{id}', user_tmpl['uriTemplate']
  end

  # --- resources/subscribe ---

  def test_resources_subscribe
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 18, 'method' => 'resources/subscribe',
      'params' => { 'uri' => 'resource:///data.json' }
    })
    assert_equal({}, resp['result'])
  end

  # --- prompts/list ---

  def test_prompts_list
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 20, 'method' => 'prompts/list', 'params' => {}
    })
    prompts = resp['result']['prompts']
    refute_nil prompts
    names = prompts.map { |p| p['name'] }
    assert_includes names, 'greet'
    assert_includes names, 'summarize'
  end

  def test_prompts_list_has_arguments
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 21, 'method' => 'prompts/list', 'params' => {}
    })
    greet = resp['result']['prompts'].find { |p| p['name'] == 'greet' }
    assert greet['arguments']
    assert_equal 2, greet['arguments'].length
  end

  # --- prompts/get ---

  def test_prompts_get
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 22, 'method' => 'prompts/get',
      'params' => { 'name' => 'greet', 'arguments' => { 'name' => 'Alice' } }
    })
    messages = resp['result']['messages']
    assert_equal 1, messages.length
    assert_equal 'user', messages[0]['role']
    assert_match(/Alice/, messages[0]['content']['text'])
  end

  def test_prompts_get_not_found
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 23, 'method' => 'prompts/get',
      'params' => { 'name' => 'nonexistent' }
    })
    assert resp['error']
    assert_equal(-32002, resp['error']['code'])
  end

  # --- logging/setLevel ---

  def test_logging_set_level
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 30, 'method' => 'logging/setLevel',
      'params' => { 'level' => 'debug' }
    })
    assert_equal({}, resp['result'])
  end

  # --- completion/complete ---

  def test_completion_complete
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 31, 'method' => 'completion/complete', 'params' => {}
    })
    assert_equal({ 'values' => [] }, resp['result']['completion'])
  end

  # --- Unknown method ---

  def test_unknown_method
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'id' => 40, 'method' => 'foo/bar'
    })
    assert resp['error']
    assert_equal(-32601, resp['error']['code'])
    assert_match(/Method not found/, resp['error']['message'])
  end

  # --- Notifications ---

  def test_notification_returns_nil
    resp = @server.handle_request({
      'jsonrpc' => '2.0', 'method' => 'notifications/initialized', 'params' => {}
    })
    assert_nil resp
  end

  # --- Pagination integration ---

  def test_tools_list_with_pagination
    config = ZeroMcp::Config.new(
      'tools' => File.join(__dir__, '..', 'tools'),
      'resources' => File.join(__dir__, 'fixtures', 'resources'),
      'prompts' => File.join(__dir__, 'fixtures', 'prompts'),
      'page_size' => 1
    )
    server = ZeroMcp::Server.new(config)
    server.load_tools

    resp = server.handle_request({
      'jsonrpc' => '2.0', 'id' => 50, 'method' => 'tools/list', 'params' => {}
    })
    assert_equal 1, resp['result']['tools'].length
    refute_nil resp['result']['nextCursor']

    # Second page
    resp2 = server.handle_request({
      'jsonrpc' => '2.0', 'id' => 51, 'method' => 'tools/list',
      'params' => { 'cursor' => resp['result']['nextCursor'] }
    })
    assert_equal 1, resp2['result']['tools'].length
    assert_nil resp2['result']['nextCursor']
  end
end
