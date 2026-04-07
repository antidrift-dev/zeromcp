# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/zeromcp/schema'

class TestSchema < Minitest::Test
  # --- to_json_schema ---

  def test_empty_input
    result = ZeroMcp::Schema.to_json_schema({})
    assert_equal 'object', result['type']
    assert_empty result['properties']
    assert_empty result['required']
  end

  def test_nil_input
    result = ZeroMcp::Schema.to_json_schema(nil)
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

  def test_all_simple_types
    types = %w[string number boolean object array]
    input = types.each_with_object({}) { |t, h| h[t] = t }
    result = ZeroMcp::Schema.to_json_schema(input)

    types.each do |t|
      assert_equal({ 'type' => t }, result['properties'][t])
      assert_includes result['required'], t
    end
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

  def test_extended_field_without_description
    result = ZeroMcp::Schema.to_json_schema({
      'count' => { 'type' => 'number' }
    })
    assert_equal({ 'type' => 'number' }, result['properties']['count'])
    refute result['properties']['count'].key?('description')
    assert_includes result['required'], 'count'
  end

  def test_symbol_keys_in_extended_field
    result = ZeroMcp::Schema.to_json_schema({
      name: { type: 'string', description: 'A name', optional: false }
    })
    assert_equal 'string', result['properties']['name']['type']
    assert_equal 'A name', result['properties']['name']['description']
    assert_includes result['required'], 'name'
  end

  def test_unknown_type_raises
    assert_raises(RuntimeError) do
      ZeroMcp::Schema.to_json_schema({ 'x' => 'uuid' })
    end
  end

  def test_unknown_type_in_extended_raises
    assert_raises(RuntimeError) do
      ZeroMcp::Schema.to_json_schema({ 'x' => { 'type' => 'bigint' } })
    end
  end

  # --- validate ---

  def test_validate_missing_required
    schema = ZeroMcp::Schema.to_json_schema({ 'name' => 'string' })
    errors = ZeroMcp::Schema.validate({}, schema)
    assert_equal 1, errors.length
    assert_match(/Missing required field: name/, errors[0])
  end

  def test_validate_multiple_missing_required
    schema = ZeroMcp::Schema.to_json_schema({ 'a' => 'string', 'b' => 'number' })
    errors = ZeroMcp::Schema.validate({}, schema)
    assert_equal 2, errors.length
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

  def test_validate_boolean_type
    schema = ZeroMcp::Schema.to_json_schema({ 'flag' => 'boolean' })
    assert_empty ZeroMcp::Schema.validate({ 'flag' => true }, schema)
    assert_empty ZeroMcp::Schema.validate({ 'flag' => false }, schema)
    errors = ZeroMcp::Schema.validate({ 'flag' => 'yes' }, schema)
    assert_equal 1, errors.length
  end

  def test_validate_array_type
    schema = ZeroMcp::Schema.to_json_schema({ 'items' => 'array' })
    assert_empty ZeroMcp::Schema.validate({ 'items' => [1, 2, 3] }, schema)
    errors = ZeroMcp::Schema.validate({ 'items' => 'not array' }, schema)
    assert_equal 1, errors.length
  end

  def test_validate_object_type
    schema = ZeroMcp::Schema.to_json_schema({ 'data' => 'object' })
    assert_empty ZeroMcp::Schema.validate({ 'data' => { 'k' => 'v' } }, schema)
    errors = ZeroMcp::Schema.validate({ 'data' => 42 }, schema)
    assert_equal 1, errors.length
  end

  def test_validate_optional_field_missing_is_ok
    schema = ZeroMcp::Schema.to_json_schema({
      'name' => 'string',
      'email' => { 'type' => 'string', 'optional' => true }
    })
    errors = ZeroMcp::Schema.validate({ 'name' => 'Alice' }, schema)
    assert_empty errors
  end

  def test_validate_extra_field_ignored
    schema = ZeroMcp::Schema.to_json_schema({ 'name' => 'string' })
    errors = ZeroMcp::Schema.validate({ 'name' => 'Alice', 'extra' => 123 }, schema)
    assert_empty errors
  end

  def test_validate_number_accepts_integer_and_float
    schema = ZeroMcp::Schema.to_json_schema({ 'n' => 'number' })
    assert_empty ZeroMcp::Schema.validate({ 'n' => 42 }, schema)
    assert_empty ZeroMcp::Schema.validate({ 'n' => 3.14 }, schema)
  end
end
