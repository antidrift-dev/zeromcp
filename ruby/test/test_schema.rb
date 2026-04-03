# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/zeromcp/schema'

class TestSchema < Minitest::Test
  def test_empty_input
    result = ZeroMcp::Schema.to_json_schema({})
    assert_equal 'object', result['type']
    assert_empty result['properties']
    assert_empty result['required']
  end

  def test_simple_types
    result = ZeroMcp::Schema.to_json_schema({ 'name' => 'string', 'age' => 'number' })
    assert_equal({ 'type' => 'string' }, result['properties']['name'])
    assert_equal({ 'type' => 'number' }, result['properties']['age'])
    assert_includes result['required'], 'name'
    assert_includes result['required'], 'age'
  end

  def test_extended_field_with_optional
    result = ZeroMcp::Schema.to_json_schema({
      'name' => { 'type' => 'string', 'description' => 'User name' },
      'email' => { 'type' => 'string', 'optional' => true }
    })
    assert_includes result['required'], 'name'
    refute_includes result['required'], 'email'
    assert_equal 'User name', result['properties']['name']['description']
  end

  def test_validate_missing_required
    schema = ZeroMcp::Schema.to_json_schema({ 'name' => 'string' })
    errors = ZeroMcp::Schema.validate({}, schema)
    assert_equal 1, errors.length
    assert_match(/Missing required field: name/, errors[0])
  end

  def test_validate_wrong_type
    schema = ZeroMcp::Schema.to_json_schema({ 'age' => 'number' })
    errors = ZeroMcp::Schema.validate({ 'age' => 'not a number' }, schema)
    assert_equal 1, errors.length
    assert_match(/expected number, got string/, errors[0])
  end

  def test_validate_passes
    schema = ZeroMcp::Schema.to_json_schema({ 'name' => 'string' })
    errors = ZeroMcp::Schema.validate({ 'name' => 'Alice' }, schema)
    assert_empty errors
  end
end
