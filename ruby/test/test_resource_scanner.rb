# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/zeromcp/config'
require_relative '../lib/zeromcp/tool'
require_relative '../lib/zeromcp/scanner'

class TestResourceScanner < Minitest::Test
  def setup
    fixtures_dir = File.join(__dir__, 'fixtures', 'resources')
    @config = ZeroMcp::Config.new(
      'tools' => File.join(__dir__, '..', 'tools'),
      'resources' => fixtures_dir
    )
    @scanner = ZeroMcp::ResourceScanner.new(@config)
    @scanner.scan
  end

  # --- Static resources ---

  def test_scans_json_file
    assert @scanner.resources.key?('data'), "Expected 'data' resource"
    res = @scanner.resources['data']
    assert_equal 'application/json', res[:mime_type]
    assert_match %r{resource:///data\.json}, res[:uri]
  end

  def test_scans_txt_file
    assert @scanner.resources.key?('notes'), "Expected 'notes' resource"
    res = @scanner.resources['notes']
    assert_equal 'text/plain', res[:mime_type]
  end

  def test_scans_md_file
    assert @scanner.resources.key?('readme'), "Expected 'readme' resource"
    res = @scanner.resources['readme']
    assert_equal 'text/markdown', res[:mime_type]
  end

  def test_static_resource_read
    res = @scanner.resources['data']
    content = res[:read].call
    assert_match(/"key"/, content)
    assert_match(/"value"/, content)
  end

  def test_static_resource_has_description
    res = @scanner.resources['notes']
    assert_match(/Static resource/, res[:description])
  end

  # --- MIME detection ---

  def test_mime_json
    assert_equal 'application/json', ZeroMcp::MIME_MAP['.json']
  end

  def test_mime_txt
    assert_equal 'text/plain', ZeroMcp::MIME_MAP['.txt']
  end

  def test_mime_md
    assert_equal 'text/markdown', ZeroMcp::MIME_MAP['.md']
  end

  def test_mime_html
    assert_equal 'text/html', ZeroMcp::MIME_MAP['.html']
  end

  def test_mime_yaml_variants
    assert_equal 'text/yaml', ZeroMcp::MIME_MAP['.yaml']
    assert_equal 'text/yaml', ZeroMcp::MIME_MAP['.yml']
  end

  def test_mime_csv
    assert_equal 'text/csv', ZeroMcp::MIME_MAP['.csv']
  end

  def test_mime_unknown_ext_defaults_to_octet_stream
    # Any extension not in MIME_MAP should default to application/octet-stream
    refute ZeroMcp::MIME_MAP.key?('.xyz')
  end

  # --- Dynamic resources ---

  def test_scans_dynamic_resource
    assert @scanner.resources.key?('status'), "Expected 'status' dynamic resource"
    res = @scanner.resources['status']
    assert_equal 'application/json', res[:mime_type]
    assert_equal 'Server status', res[:description]
  end

  def test_dynamic_resource_read
    res = @scanner.resources['status']
    content = res[:read].call
    parsed = JSON.parse(content)
    assert_equal 'ok', parsed['status']
    assert_equal 12345, parsed['uptime']
  end

  # --- Template resources ---

  def test_scans_template_resource
    assert @scanner.templates.key?('user'), "Expected 'user' template resource"
    tmpl = @scanner.templates['user']
    assert_equal 'user:///{id}', tmpl[:uri_template]
    assert_equal 'application/json', tmpl[:mime_type]
    assert_equal 'Fetch user by ID', tmpl[:description]
  end

  def test_template_resource_read_with_params
    tmpl = @scanner.templates['user']
    content = tmpl[:read].call({ 'id' => '42' })
    parsed = JSON.parse(content)
    assert_equal '42', parsed['id']
    assert_equal 'User 42', parsed['name']
  end

  # --- Missing directory ---

  def test_missing_resource_dir_no_error
    config = ZeroMcp::Config.new(
      'tools' => File.join(__dir__, '..', 'tools'),
      'resources' => '/nonexistent/path'
    )
    scanner = ZeroMcp::ResourceScanner.new(config)
    scanner.scan
    assert_empty scanner.resources
    assert_empty scanner.templates
  end
end
