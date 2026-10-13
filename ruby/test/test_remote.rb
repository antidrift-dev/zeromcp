# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../lib/zeromcp'
require_relative 'fake_upstream'

class TestRemote < Minitest::Test
  def setup
    @upstream = FakeUpstream.new
    @empty_dir = Dir.mktmpdir
  end

  def teardown
    @upstream.stop
    FileUtils.rm_rf(@empty_dir)
  end

  def server_for(remote, tools_dir: @empty_dir, separator: '_')
    config = ZeroMcp::Config.new('tools' => tools_dir, 'remote' => remote, 'separator' => separator)
    server = ZeroMcp::Server.new(config)
    server.load_tools
    server
  end

  def list_names(server)
    server.handle_request({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list' })['result']['tools'].map { |t| t['name'] }
  end

  def test_remote_tools_are_listed_namespaced
    server = nil
    _, err = capture_io { server = server_for([{ 'name' => 'probeo', 'url' => @upstream.url }]) }
    assert_equal ['probeo.list_pages', 'probeo.get_page'], list_names(server)
    assert_includes err, '[mcp] Remote tool: probeo.list_pages'
    assert_includes err, '[mcp] Connected to probeo (HTTP): 2 tool(s)'
  end

  def test_initialize_and_tools_list_are_sent_in_order
    capture_io { server_for([{ 'name' => 'probeo', 'url' => @upstream.url }]) }
    assert_equal [['initialize', 1], ['tools/list', 2]], @upstream.requests.map { |r| [r[:body]['method'], r[:body]['id']] }
  end

  def test_remote_tool_call_returns_upstream_text
    server = nil
    capture_io { server = server_for([{ 'name' => 'probeo', 'url' => @upstream.url }]) }
    resp = server.handle_request({
      'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/call',
      'params' => { 'name' => 'probeo.list_pages', 'arguments' => { 'domain' => 'example.com' } }
    })
    text = resp['result']['content'][0]['text']
    assert_equal({ 'pages' => [], 'tool' => 'list_pages', 'args' => { 'domain' => 'example.com' } }, JSON.parse(text))
    refute resp['result']['isError']
  end

  def test_allowlist_keeps_only_listed_tools
    server = nil
    capture_io { server = server_for([{ 'name' => 'probeo', 'url' => @upstream.url, 'tools' => ['list_pages'] }]) }
    assert_equal ['probeo.list_pages'], list_names(server)
  end

  def test_symbol_keys_are_accepted
    tools = nil
    capture_io { tools = ZeroMcp::Remote.connect([{ name: 'probeo', url: @upstream.url, tools: ['get_page'] }]) }
    assert_equal ['probeo.get_page'], tools.keys
  end

  def test_bearer_auth_is_sent
    capture_io { server_for([{ 'name' => 'probeo', 'url' => @upstream.url, 'auth' => 'secret-token' }]) }
    assert(@upstream.requests.all? { |r| r[:authorization] == 'Bearer secret-token' })
  end

  def test_env_auth_resolves_from_env
    ENV['ZEROMCP_TEST_REMOTE_TOKEN'] = 'from-env'
    server = nil
    capture_io { server = server_for([{ 'name' => 'probeo', 'url' => @upstream.url, 'auth' => 'env:ZEROMCP_TEST_REMOTE_TOKEN' }]) }
    server.handle_request({
      'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/call',
      'params' => { 'name' => 'probeo.get_page', 'arguments' => { 'url' => 'x' } }
    })
    assert_equal 3, @upstream.requests.size
    assert(@upstream.requests.all? { |r| r[:authorization] == 'Bearer from-env' })
  ensure
    ENV.delete('ZEROMCP_TEST_REMOTE_TOKEN')
  end

  def test_no_auth_header_without_auth
    capture_io { server_for([{ 'name' => 'probeo', 'url' => @upstream.url }]) }
    assert(@upstream.requests.all? { |r| r[:authorization].nil? })
  end

  def test_bad_servers_are_logged_and_skipped
    broken = FakeUpstream.new(status: 500)
    server = nil
    _, err = capture_io do
      server = server_for([
        { 'name' => 'stdio', 'url' => 'stdio://nope' },
        { 'name' => 'broken', 'url' => broken.url },
        { 'name' => 'probeo', 'url' => @upstream.url }
      ])
    end
    assert_includes err, '[mcp] Failed to connect to stdio: Remote server "stdio" must have an HTTP/HTTPS URL, got: stdio://nope'
    assert_includes err, '[mcp] Failed to connect to broken: HTTP 500'
    assert_equal ['probeo.list_pages', 'probeo.get_page'], list_names(server)
  ensure
    broken&.stop
  end

  def test_local_tool_overrides_remote
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'probeo'))
      File.write(File.join(dir, 'probeo', 'list_pages.rb'), <<~RUBY)
        tool description: 'Local list_pages', input: {}
        execute { |_args, _ctx| 'local' }
      RUBY

      server = nil
      _, err = capture_io { server = server_for([{ 'name' => 'probeo', 'url' => @upstream.url }], tools_dir: dir, separator: '.') }
      assert_includes err, '[zeromcp] Local tool "probeo.list_pages" overrides remote'
      assert_equal ['probeo.list_pages', 'probeo.get_page'], list_names(server)

      resp = server.handle_request({
        'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/call',
        'params' => { 'name' => 'probeo.list_pages', 'arguments' => {} }
      })
      assert_equal 'local', resp['result']['content'][0]['text']
      assert_empty @upstream.calls
    end
  end

  def test_remote_tools_have_no_route
    tools = nil
    capture_io { tools = ZeroMcp::Remote.connect([{ 'name' => 'probeo', 'url' => @upstream.url }]) }
    assert(tools.values.all? { |t| t.route.nil? })
  end

  # --- schema_to_input ---

  def test_schema_to_input_required_without_description_is_bare_type
    input = ZeroMcp::Remote.schema_to_input({ 'properties' => { 'a' => { 'type' => 'number' } }, 'required' => ['a'] })
    assert_equal({ 'a' => 'number' }, input)
  end

  def test_schema_to_input_defaults_type_to_string
    input = ZeroMcp::Remote.schema_to_input({ 'properties' => { 'a' => {} }, 'required' => ['a'] })
    assert_equal({ 'a' => 'string' }, input)
  end

  def test_schema_to_input_keeps_description
    input = ZeroMcp::Remote.schema_to_input({ 'properties' => { 'a' => { 'type' => 'string', 'description' => 'An A' } }, 'required' => ['a'] })
    assert_equal({ 'a' => { type: 'string', description: 'An A' } }, input)
  end

  def test_schema_to_input_marks_unrequired_optional
    input = ZeroMcp::Remote.schema_to_input({ 'properties' => { 'a' => { 'type' => 'boolean' } } })
    assert_equal({ 'a' => { type: 'boolean', optional: true } }, input)
  end

  def test_schema_to_input_without_properties_is_empty
    assert_equal({}, ZeroMcp::Remote.schema_to_input({ 'type' => 'object' }))
    assert_equal({}, ZeroMcp::Remote.schema_to_input(nil))
  end

  # --- resolve_auth ---

  def test_resolve_auth_literal_and_nil
    assert_equal 'abc', ZeroMcp::Config.resolve_auth('abc')
    assert_nil ZeroMcp::Config.resolve_auth(nil)
  end

  def test_resolve_auth_unset_env_warns
    ENV.delete('ZEROMCP_TEST_UNSET_VAR')
    result = nil
    _, err = capture_io { result = ZeroMcp::Config.resolve_auth('env:ZEROMCP_TEST_UNSET_VAR') }
    assert_nil result
    assert_includes err, '[zeromcp] Warning: environment variable ZEROMCP_TEST_UNSET_VAR not set'
  end
end
