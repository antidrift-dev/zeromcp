# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/zeromcp'
require_relative 'fake_upstream'

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

  # --- remote ---

  def with_upstream
    upstream = FakeUpstream.new
    yield upstream
  ensure
    upstream&.stop
  end

  def test_remote_tools_are_served_from_mcp
    with_upstream do |upstream|
      registry = nil
      capture_io { registry = ZeroMcp.create_registry({ 'greet' => routed_tool }, remote: [{ 'name' => 'probeo', 'url' => upstream.url }]) }
      names = registry.mcp.call({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list' })['result']['tools'].map { |t| t['name'] }
      assert_equal ['probeo.list_pages', 'probeo.get_page', 'greet'], names

      resp = registry.mcp.call({
        'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/call',
        'params' => { 'name' => 'probeo.get_page', 'arguments' => { 'url' => 'https://x' } }
      })
      assert_equal 'get_page', JSON.parse(resp['result']['content'][0]['text'])['tool']
    end
  end

  def test_remote_tools_are_absent_from_routes_and_openapi
    with_upstream do |upstream|
      registry = nil
      capture_io { registry = ZeroMcp.create_registry({ 'greet' => routed_tool }, remote: [{ 'name' => 'probeo', 'url' => upstream.url }]) }
      assert_equal ['greet'], registry.routes.map(&:name)
      assert_equal ['/greet/{name}'], registry.openapi['paths'].keys
    end
  end

  def test_remote_from_config
    with_upstream do |upstream|
      config = ZeroMcp::Config.new('remote' => [{ 'name' => 'probeo', 'url' => upstream.url, 'tools' => ['list_pages'] }])
      registry = nil
      capture_io { registry = ZeroMcp.create_registry({}, config: config) }
      names = registry.mcp.call({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list' })['result']['tools'].map { |t| t['name'] }
      assert_equal ['probeo.list_pages'], names
    end
  end

  def test_local_tool_overrides_remote
    with_upstream do |upstream|
      local = ZeroMcp::Tool.new(name: 'probeo.list_pages', description: 'local') { |_args, _ctx| 'local' }
      registry = nil
      _, err = capture_io do
        registry = ZeroMcp.create_registry({ 'probeo.list_pages' => local }, remote: [{ 'name' => 'probeo', 'url' => upstream.url }])
      end
      assert_includes err, '[zeromcp] Local tool "probeo.list_pages" overrides remote'
      resp = registry.mcp.call({
        'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/call',
        'params' => { 'name' => 'probeo.list_pages', 'arguments' => {} }
      })
      assert_equal 'local', resp['result']['content'][0]['text']
      assert_empty upstream.calls
    end
  end

  # --- get_runtime ---

  def runtime_tool
    ZeroMcp::Tool.new(name: 'whoami', description: 'runtime', route: { method: 'GET', path: '/whoami' }) do |_args, ctx|
      ctx.runtime
    end
  end

  def test_get_runtime_reaches_tool_via_mcp
    registry = ZeroMcp.create_registry({ 'whoami' => runtime_tool }, get_runtime: -> { { 'db' => 'x' } })
    resp = registry.mcp.call({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/call', 'params' => { 'name' => 'whoami' } })
    assert_equal '{"db":"x"}', resp['result']['content'][0]['text']
  end

  def test_get_runtime_reaches_tool_via_context_for
    registry = ZeroMcp.create_registry({ 'whoami' => runtime_tool }, get_runtime: -> { { 'db' => 'x' } })
    route = registry.routes[0]
    assert_equal({ 'db' => 'x' }, route.tool.call({}, registry.context_for(route.tool)))
  end

  def test_no_get_runtime_leaves_runtime_nil
    registry = ZeroMcp.create_registry({ 'whoami' => runtime_tool })
    assert_nil registry.context_for(registry.routes[0].tool).runtime
  end

  def test_get_runtime_is_not_called_for_remote_tools
    with_upstream do |upstream|
      calls = 0
      registry = nil
      capture_io do
        registry = ZeroMcp.create_registry({}, remote: [{ 'name' => 'probeo', 'url' => upstream.url }],
                                               get_runtime: -> { calls += 1 })
      end
      registry.mcp.call({
        'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/call',
        'params' => { 'name' => 'probeo.get_page', 'arguments' => { 'url' => 'u' } }
      })
      assert_equal 0, calls
    end
  end
end
