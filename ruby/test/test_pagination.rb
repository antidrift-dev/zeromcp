# frozen_string_literal: true

require 'minitest/autorun'
require 'base64'
require_relative '../lib/zeromcp/config'
require_relative '../lib/zeromcp/tool'
require_relative '../lib/zeromcp/scanner'
require_relative '../lib/zeromcp/server'

class TestPagination < Minitest::Test
  def setup
    @config = ZeroMcp::Config.new(
      'tools' => File.join(__dir__, '..', 'tools'),
      'page_size' => 2
    )
    @server = ZeroMcp::Server.new(@config)
    # Access private pagination methods via send
  end

  def test_encode_cursor_round_trip
    encoded = @server.send(:encode_cursor, 10)
    decoded = @server.send(:decode_cursor, encoded)
    assert_equal 10, decoded
  end

  def test_encode_cursor_zero
    encoded = @server.send(:encode_cursor, 0)
    decoded = @server.send(:decode_cursor, encoded)
    assert_equal 0, decoded
  end

  def test_decode_cursor_invalid_returns_zero
    decoded = @server.send(:decode_cursor, '!!!invalid!!!')
    assert_equal 0, decoded
  end

  def test_decode_cursor_negative_returns_zero
    encoded = Base64.strict_encode64('-5')
    decoded = @server.send(:decode_cursor, encoded)
    assert_equal 0, decoded
  end

  def test_paginate_no_pagination_when_page_size_zero
    config = ZeroMcp::Config.new('tools' => File.join(__dir__, '..', 'tools'), 'page_size' => 0)
    server = ZeroMcp::Server.new(config)
    items = %w[a b c d e]
    result, next_cursor = server.send(:paginate, items, nil)
    assert_equal items, result
    assert_nil next_cursor
  end

  def test_paginate_first_page
    items = %w[a b c d e]
    result, next_cursor = @server.send(:paginate, items, nil)
    assert_equal %w[a b], result
    refute_nil next_cursor
  end

  def test_paginate_middle_page
    items = %w[a b c d e]
    _first, cursor1 = @server.send(:paginate, items, nil)
    result, cursor2 = @server.send(:paginate, items, cursor1)
    assert_equal %w[c d], result
    refute_nil cursor2
  end

  def test_paginate_last_page
    items = %w[a b c d e]
    _, cursor1 = @server.send(:paginate, items, nil)
    _, cursor2 = @server.send(:paginate, items, cursor1)
    result, cursor3 = @server.send(:paginate, items, cursor2)
    assert_equal %w[e], result
    assert_nil cursor3
  end

  def test_paginate_empty_list
    result, next_cursor = @server.send(:paginate, [], nil)
    assert_empty result
    assert_nil next_cursor
  end

  def test_paginate_exact_fit
    items = %w[a b]
    result, next_cursor = @server.send(:paginate, items, nil)
    assert_equal %w[a b], result
    assert_nil next_cursor
  end
end
