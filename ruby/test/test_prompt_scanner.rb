# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/zeromcp/config'
require_relative '../lib/zeromcp/tool'
require_relative '../lib/zeromcp/scanner'

class TestPromptScanner < Minitest::Test
  def setup
    fixtures_dir = File.join(__dir__, 'fixtures', 'prompts')
    @config = ZeroMcp::Config.new(
      'tools' => File.join(__dir__, '..', 'tools'),
      'prompts' => fixtures_dir
    )
    @scanner = ZeroMcp::PromptScanner.new(@config)
    @scanner.scan
  end

  def test_scans_greet_prompt
    assert @scanner.prompts.key?('greet'), "Expected 'greet' prompt"
    prompt = @scanner.prompts['greet']
    assert_equal 'Generate a greeting', prompt[:description]
  end

  def test_scans_summarize_prompt
    assert @scanner.prompts.key?('summarize'), "Expected 'summarize' prompt"
    prompt = @scanner.prompts['summarize']
    assert_equal 'Summarize a document', prompt[:description]
  end

  def test_prompt_arguments_structure
    prompt = @scanner.prompts['greet']
    args = prompt[:arguments]
    refute_nil args
    assert_equal 2, args.length

    name_arg = args.find { |a| a['name'] == 'name' }
    style_arg = args.find { |a| a['name'] == 'style' }

    refute_nil name_arg
    assert_equal true, name_arg['required']

    refute_nil style_arg
    assert_equal false, style_arg['required']
    assert_equal 'Greeting style', style_arg['description']
  end

  def test_prompt_simple_string_argument
    prompt = @scanner.prompts['summarize']
    args = prompt[:arguments]
    refute_nil args
    assert_equal 1, args.length
    assert_equal 'text', args[0]['name']
    assert_equal true, args[0]['required']
  end

  def test_prompt_render
    prompt = @scanner.prompts['greet']
    messages = prompt[:render].call({ 'name' => 'Alice' })
    assert_equal 1, messages.length
    assert_equal 'user', messages[0]['role']
    assert_match(/Alice/, messages[0]['content']['text'])
    assert_match(/friendly/, messages[0]['content']['text'])
  end

  def test_prompt_render_with_optional_arg
    prompt = @scanner.prompts['greet']
    messages = prompt[:render].call({ 'name' => 'Bob', 'style' => 'formal' })
    assert_match(/formal/, messages[0]['content']['text'])
  end

  def test_missing_prompts_dir_no_error
    config = ZeroMcp::Config.new(
      'tools' => File.join(__dir__, '..', 'tools'),
      'prompts' => '/nonexistent/path'
    )
    scanner = ZeroMcp::PromptScanner.new(config)
    scanner.scan
    assert_empty scanner.prompts
  end
end
