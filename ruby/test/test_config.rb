# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'base64'
require_relative '../lib/zeromcp/config'

class TestConfig < Minitest::Test
  def test_defaults
    config = ZeroMcp::Config.new
    assert_equal ['./tools'], config.tools_dir
    assert_empty config.resources_dir
    assert_empty config.prompts_dir
    assert_equal '_', config.separator
    assert_equal false, config.logging
    assert_equal false, config.bypass_permissions
    assert_equal 30, config.execute_timeout
    assert_equal 0, config.page_size
    assert_nil config.icon
  end

  def test_string_keys
    config = ZeroMcp::Config.new(
      'tools' => '/my/tools',
      'resources' => '/my/resources',
      'prompts' => '/my/prompts',
      'separator' => '::',
      'logging' => true,
      'bypass_permissions' => true,
      'execute_timeout' => 60,
      'page_size' => 10,
      'icon' => 'icon.png'
    )
    assert_equal ['/my/tools'], config.tools_dir
    assert_equal ['/my/resources'], config.resources_dir
    assert_equal ['/my/prompts'], config.prompts_dir
    assert_equal '::', config.separator
    assert_equal true, config.logging
    assert_equal true, config.bypass_permissions
    assert_equal 60, config.execute_timeout
    assert_equal 10, config.page_size
    assert_equal 'icon.png', config.icon
  end

  def test_symbol_keys
    config = ZeroMcp::Config.new(
      tools_dir: '/sym/tools',
      resources_dir: ['/res/a', '/res/b'],
      prompts_dir: '/sym/prompts',
      separator: '-'
    )
    assert_equal ['/sym/tools'], config.tools_dir
    assert_equal ['/res/a', '/res/b'], config.resources_dir
    assert_equal ['/sym/prompts'], config.prompts_dir
    assert_equal '-', config.separator
  end

  def test_array_dirs
    config = ZeroMcp::Config.new(
      'tools' => ['/a', '/b'],
      'resources' => ['/r1', '/r2'],
      'prompts' => ['/p1']
    )
    assert_equal ['/a', '/b'], config.tools_dir
    assert_equal ['/r1', '/r2'], config.resources_dir
    assert_equal ['/p1'], config.prompts_dir
  end

  def test_load_from_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'zeromcp.config.json')
      File.write(path, JSON.generate({
        'tools' => '/from/file',
        'separator' => '.',
        'page_size' => 5
      }))
      config = ZeroMcp::Config.load(path)
      assert_equal ['/from/file'], config.tools_dir
      assert_equal '.', config.separator
      assert_equal 5, config.page_size
    end
  end

  def test_load_missing_file_returns_defaults
    config = ZeroMcp::Config.load('/nonexistent/zeromcp.config.json')
    assert_equal ['./tools'], config.tools_dir
    assert_equal '_', config.separator
  end

  def test_load_invalid_json_returns_defaults
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'zeromcp.config.json')
      File.write(path, 'not valid json {{{')
      config = ZeroMcp::Config.load(path)
      assert_equal ['./tools'], config.tools_dir
    end
  end

  # --- Icon resolution ---

  def test_resolve_icon_nil
    assert_nil ZeroMcp::Config.resolve_icon(nil)
  end

  def test_resolve_icon_empty
    assert_nil ZeroMcp::Config.resolve_icon('')
  end

  def test_resolve_icon_data_uri_passthrough
    uri = 'data:image/png;base64,abc123'
    assert_equal uri, ZeroMcp::Config.resolve_icon(uri)
  end

  def test_resolve_icon_from_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'icon.png')
      png_header = "\x89PNG\r\n\x1a\n".b
      File.binwrite(path, png_header + 'fake png data'.b)
      result = ZeroMcp::Config.resolve_icon(path)
      prefix = 'data:image/png;base64,'
      assert result.start_with?(prefix)
      decoded = Base64.strict_decode64(result[prefix.length..])
      assert decoded.b.start_with?(png_header)
    end
  end

  def test_resolve_icon_svg
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'icon.svg')
      File.write(path, '<svg></svg>')
      result = ZeroMcp::Config.resolve_icon(path)
      assert result.start_with?('data:image/svg+xml;base64,')
    end
  end

  def test_resolve_icon_missing_file
    assert_nil ZeroMcp::Config.resolve_icon('/nonexistent/icon.png')
  end
end
