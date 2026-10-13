# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'

# Run in a subprocess so a webrick loaded by another test can't mask a regression.
class TestWebrickOptional < Minitest::Test
  LIB = File.expand_path('../lib', __dir__)

  BLOCK_WEBRICK = <<~RUBY
    module Kernel
      alias_method :__zeromcp_test_require, :require
      def require(name)
        raise LoadError, 'cannot load such file -- webrick' if name == 'webrick'
        __zeromcp_test_require(name)
      end
    end
  RUBY

  def run_ruby(script)
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', LIB, '-e', script)
    assert status.success?, "subprocess failed:\n#{err}"
    out.strip
  end

  def test_loading_zeromcp_does_not_load_webrick
    out = run_ruby(<<~RUBY)
      require 'zeromcp'
      puts $LOADED_FEATURES.any? { |f| f.end_with?('/webrick.rb') }
    RUBY
    assert_equal 'false', out
  end

  def test_zeromcp_loads_and_handles_requests_without_webrick
    out = run_ruby(BLOCK_WEBRICK + <<~RUBY)
      require 'zeromcp'
      server = ZeroMcp::Server.new(ZeroMcp::Config.new({}))
      res = server.handle_request({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'ping' })
      puts res['id']
    RUBY
    assert_equal '1', out
  end

  def test_serve_http_without_webrick_raises_clear_error
    out = run_ruby(BLOCK_WEBRICK + <<~RUBY)
      require 'zeromcp'
      begin
        ZeroMcp::Server.new(ZeroMcp::Config.new({})).serve_http(port: 0)
      rescue LoadError => e
        puts e.message
      end
    RUBY
    assert_equal 'webrick is required for the HTTP transport: gem install webrick (or add it to your Gemfile)', out
  end
end
