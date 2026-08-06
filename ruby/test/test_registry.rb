# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/zeromcp'

class TestRegistry < Minitest::Test
  def routed_tool(method: 'GET', path: '/greet/:name')
    ZeroMcp::Tool.new(
      name: 'greet', description: 'Greet someone', input: { 'name' => 'string' },
      route: { method: method, path: path }
    ) { |args, _ctx| "hi #{args['name']}" }
  end

  def unrouted_tool
    ZeroMcp::Tool.new(name: 'hidden', description: 'No route') { |_args, _ctx| '' }
  end

  def test_routes_only_includes_routed_tools
    registry = ZeroMcp.create_registry({ 'greet' => routed_tool, 'hidden' => unrouted_tool })
    assert_equal 1, registry.routes.size
    assert_equal 'greet', registry.routes[0].name
    assert_equal 'GET', registry.routes[0].method
    assert_equal '/greet/:name', registry.routes[0].path
  end

  def test_routes_preserve_insertion_order
    tools = {
      'charlie' => routed_tool(path: '/charlie'),
      'alpha' => routed_tool(path: '/alpha'),
      'bravo' => routed_tool(path: '/bravo')
    }
    registry = ZeroMcp.create_registry(tools)
    assert_equal %w[charlie alpha bravo], registry.routes.map(&:name)
  end

  def test_openapi_matches_routed_tools
    registry = ZeroMcp.create_registry({ 'greet' => routed_tool })
    assert registry.openapi['paths'].key?('/greet/{name}')
  end

  def test_route_tool_invoked_directly_produces_expected_result
    registry = ZeroMcp.create_registry({ 'greet' => routed_tool })
    route = registry.routes[0]
    ctx = registry.context_for(route.tool)
    result = route.tool.call({ 'name' => 'Ada' }, ctx)
    assert_equal 'hi Ada', result
  end

  def test_context_for_builds_credential_backed_context
    registry = ZeroMcp.create_registry({ 'greet' => routed_tool })
    ctx = registry.context_for(registry.routes[0].tool)
    assert_instance_of ZeroMcp::Context, ctx
    assert_equal 'greet', ctx.tool_name
  end

  def test_mcp_dispatches_tools_list
    registry = ZeroMcp.create_registry({ 'greet' => routed_tool })
    resp = registry.mcp.call({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list' })
    tools = resp['result']['tools']
    assert_equal 1, tools.size
    assert_equal 'greet', tools[0]['name']
  end

  def test_mcp_dispatches_tools_call
    registry = ZeroMcp.create_registry({ 'greet' => routed_tool(method: 'POST', path: '/greet') })
    resp = registry.mcp.call({
      'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/call',
      'params' => { 'name' => 'greet', 'arguments' => { 'name' => 'Ada' } }
    })
    assert_equal 'hi Ada', resp['result']['content'][0]['text']
  end

  def test_empty_when_no_routed_tools
    registry = ZeroMcp.create_registry({ 'hidden' => unrouted_tool })
    assert_equal 0, registry.routes.size
  end

  def test_default_config_does_not_read_from_disk
    # Should build cleanly with in-memory defaults, not attempt to load
    # ./zeromcp.config.json from the process cwd.
    registry = ZeroMcp.create_registry({ 'greet' => routed_tool })
    assert_equal 'ZeroMCP', registry.config.title
    assert_equal 30, registry.config.execute_timeout
  end

  def test_title_and_execute_timeout_kwargs_are_threaded_through
    registry = ZeroMcp.create_registry({ 'greet' => routed_tool }, title: 'My API', execute_timeout: 5)
    assert_equal 'My API', registry.config.title
    assert_equal 5, registry.config.execute_timeout
    assert_equal 'My API', registry.openapi['info']['title']
  end
end
