# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require 'json'
require_relative '../lib/zeromcp'

class TestAutoload < Minitest::Test
  TOOL = <<~RUBY
    tool description: 'A tool', input: {}
    execute { |_args, _ctx| 'ok' }
  RUBY

  def wait_for(timeout = 3)
    deadline = Time.now + timeout
    until yield
      return false if Time.now > deadline
      sleep 0.05
    end
    true
  end

  def list_names(server)
    server.handle_request({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list' })['result']['tools'].map { |t| t['name'] }
  end

  def test_config_reads_autoload_tools
    assert_equal false, ZeroMcp::Config.new.autoload_tools
    assert_equal true, ZeroMcp::Config.new('autoload_tools' => true).autoload_tools
  end

  def test_new_tool_file_is_loaded_and_list_changed_sent
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'first.rb'), TOOL)
      server = ZeroMcp::Server.new(ZeroMcp::Config.new('tools' => dir, 'autoload_tools' => true))
      out = StringIO.new
      old_stdout = $stdout
      old_stderr = $stderr
      err = StringIO.new
      $stderr = err
      begin
        server.load_tools
        # Same notify hook serve installs for the stdio transport.
        server.instance_variable_set(:@notify, lambda { |method, params|
          server.send(:write_message, { 'jsonrpc' => '2.0', 'method' => method, 'params' => params })
        })
        $stdout = out
        server.send(:start_autoload, interval: 0.05)
        assert_equal ['first'], list_names(server)

        sleep 0.1
        File.write(File.join(dir, 'second.rb'), TOOL)

        assert wait_for { list_names(server).include?('second') }, 'second tool was not loaded'
        assert wait_for { out.string.include?('list_changed') }, 'no list_changed notification'
      ensure
        server.send(:stop_autoload)
        $stdout = old_stdout
        $stderr = old_stderr
      end

      assert_equal %w[first second], list_names(server)
      line = out.string.lines.first
      assert_equal({ 'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed', 'params' => {} }, JSON.parse(line))
      assert_includes err.string, '[zeromcp] autoload_tools enabled — watching for changes'
      assert_includes err.string, '[zeromcp] Change detected: second.rb'
    end
  end

  def test_removed_file_keeps_tool_like_node
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'first.rb'), TOOL)
      File.write(File.join(dir, 'gone.rb'), TOOL)
      server = ZeroMcp::Server.new(ZeroMcp::Config.new('tools' => dir))
      capture_io do
        server.load_tools
        server.send(:start_autoload, interval: 0.05)
        sleep 0.1
        File.delete(File.join(dir, 'gone.rb'))
        sleep 0.3
        server.send(:stop_autoload)
      end
      assert_equal %w[first gone], list_names(server)
    end
  end

  def test_no_notification_without_stdio
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'first.rb'), TOOL)
      server = ZeroMcp::Server.new(ZeroMcp::Config.new('tools' => dir))
      out, = capture_io do
        server.load_tools
        server.send(:start_autoload, interval: 0.05)
        sleep 0.1
        File.write(File.join(dir, 'second.rb'), TOOL)
        wait_for { list_names(server).include?('second') }
        server.send(:stop_autoload)
      end
      assert_includes list_names(server), 'second'
      assert_empty out
    end
  end
end
