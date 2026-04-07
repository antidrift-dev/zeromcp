# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/zeromcp/server'

class TestTemplateMatching < Minitest::Test
  def setup
    @config = ZeroMcp::Config.new(
      'tools' => File.join(__dir__, '..', 'tools')
    )
    @server = ZeroMcp::Server.new(@config)
  end

  def test_single_param
    result = @server.send(:match_template, 'user:///{id}', 'user:///42')
    refute_nil result
    assert_equal '42', result['id']
  end

  def test_multiple_params
    result = @server.send(:match_template, 'org:///{org}/repo/{repo}', 'org:///acme/repo/widgets')
    refute_nil result
    assert_equal 'acme', result['org']
    assert_equal 'widgets', result['repo']
  end

  def test_no_match
    result = @server.send(:match_template, 'user:///{id}', 'other:///42')
    assert_nil result
  end

  def test_no_match_extra_segments
    result = @server.send(:match_template, 'user:///{id}', 'user:///42/extra')
    assert_nil result
  end

  def test_no_match_missing_segment
    result = @server.send(:match_template, 'user:///{id}/profile', 'user:///42')
    assert_nil result
  end

  def test_empty_param_no_match
    # {id} requires at least one non-slash char via [^/]+
    result = @server.send(:match_template, 'user:///{id}', 'user:///')
    assert_nil result
  end

  def test_literal_template_exact_match
    result = @server.send(:match_template, 'resource:///static', 'resource:///static')
    refute_nil result
    assert_empty result
  end

  def test_literal_template_no_match
    result = @server.send(:match_template, 'resource:///static', 'resource:///other')
    assert_nil result
  end

  def test_param_with_encoded_chars
    result = @server.send(:match_template, 'file:///{path}', 'file:///hello%20world')
    refute_nil result
    assert_equal 'hello%20world', result['path']
  end
end
