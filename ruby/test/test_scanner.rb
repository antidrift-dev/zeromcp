# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/zeromcp/config'
require_relative '../lib/zeromcp/tool'
require_relative '../lib/zeromcp/scanner'

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
end
