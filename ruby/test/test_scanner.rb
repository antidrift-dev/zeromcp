# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/zeromcp'

class TestScanner < Minitest::Test
  def test_scan_loads_tools
    config = ZeroMcp::Config.new(
      'tools' => File.join(__dir__, '..', 'tools')
    )
    scanner = ZeroMcp::Scanner.new(config)
    tools = scanner.scan

    assert tools.key?('hello'), "Expected 'hello' tool to be loaded"
    tool = tools['hello']
    assert_equal 'Say hello to someone', tool.description
    assert_equal 'Hello, World!', tool.call({ 'name' => 'World' }, nil)
  end

  TOOL = <<~RUBY
    tool description: 'A tool', input: {}
    execute { |_args, ctx| ctx.respond_to?(:credentials) ? ctx.credentials : nil }
  RUBY

  # tmp/
  #   hello.rb
  #   math/add.rb
  def with_tree
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'hello.rb'), TOOL)
      FileUtils.mkdir_p(File.join(dir, 'math'))
      File.write(File.join(dir, 'math', 'add.rb'), TOOL)
      yield dir
    end
  end

  def scan(opts)
    tools = nil
    capture_io { tools = ZeroMcp::Scanner.new(ZeroMcp::Config.new(opts)).scan }
    tools
  end

  def test_source_prefix
    with_tree do |dir|
      tools = scan('tools' => [{ 'path' => dir, 'prefix' => 'x' }])
      assert_equal %w[x_hello x_math_add], tools.keys.sort
    end
  end

  def test_mixed_sources
    with_tree do |dir|
      Dir.mktmpdir do |other|
        File.write(File.join(other, 'ping.rb'), TOOL)
        tools = scan('tools' => [dir, { 'path' => other, 'prefix' => 'ext' }])
        assert_equal %w[ext_ping hello math_add], tools.keys.sort
      end
    end
  end

  def test_namespacing_override
    with_tree do |dir|
      tools = scan('tools' => dir, 'namespacing' => { 'math' => { 'prefix' => 'm' } })
      assert_equal %w[hello m_add], tools.keys.sort
    end
  end

  def test_namespacing_symbol_keys
    with_tree do |dir|
      tools = scan('tools' => dir, 'namespacing' => { math: { prefix: 'm' } })
      assert_equal %w[hello m_add], tools.keys.sort
    end
  end

  def test_namespacing_empty_prefix_drops_dir
    with_tree do |dir|
      tools = scan('tools' => dir, 'namespacing' => { 'math' => { 'prefix' => '' } })
      assert_equal %w[add hello], tools.keys.sort
    end
  end

  def test_namespacing_and_source_prefix_combine
    with_tree do |dir|
      tools = scan('tools' => [{ 'path' => dir, 'prefix' => 'x' }], 'separator' => '.', 'namespacing' => { 'math' => { 'prefix' => 'm' } })
      assert_equal %w[x.hello x.m.add], tools.keys.sort
    end
  end

  def test_credentials_resolve_by_directory_under_namespacing
    with_tree do |dir|
      ENV['ZEROMCP_TEST_MATH_CREDS'] = 'math-secret'
      config = ZeroMcp::Config.new(
        'tools' => dir,
        'namespacing' => { 'math' => { 'prefix' => 'm' } },
        'credentials' => { 'math' => { 'env' => 'ZEROMCP_TEST_MATH_CREDS' } }
      )
      server = ZeroMcp::Server.new(config)
      capture_io { server.load_tools }
      tool = server.instance_variable_get(:@tools)['m_add']
      assert_equal 'math', tool.credentials_ns
      resp = server.handle_request({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/call', 'params' => { 'name' => 'm_add' } })
      assert_equal 'math-secret', resp['result']['content'][0]['text']
    ensure
      ENV.delete('ZEROMCP_TEST_MATH_CREDS')
    end
  end

  def test_top_level_tool_has_no_credentials_ns
    with_tree do |dir|
      tools = scan('tools' => dir)
      assert_nil tools['hello'].credentials_ns
      assert_equal 'math', tools['math_add'].credentials_ns
    end
  end
end
