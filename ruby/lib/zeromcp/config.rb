# frozen_string_literal: true

require 'json'
require 'base64'

module ZeroMcp
  class Config
    attr_reader :tools_dir, :resources_dir, :prompts_dir,
                :separator, :logging, :bypass_permissions, :execute_timeout,
                :page_size, :icon

    def initialize(opts = {})
      tools = opts[:tools_dir] || opts['tools'] || './tools'
      @tools_dir = tools.is_a?(Array) ? tools : [tools]

      resources = opts[:resources_dir] || opts['resources']
      @resources_dir = resources ? (resources.is_a?(Array) ? resources : [resources]) : []

      prompts = opts[:prompts_dir] || opts['prompts']
      @prompts_dir = prompts ? (prompts.is_a?(Array) ? prompts : [prompts]) : []

      @separator = opts[:separator] || opts['separator'] || '_'
      @logging = opts[:logging] || opts['logging'] || false
      @bypass_permissions = opts[:bypass_permissions] || opts['bypass_permissions'] || false
      @execute_timeout = opts[:execute_timeout] || opts['execute_timeout'] || 30 # seconds
      @credentials = opts[:credentials] || opts['credentials'] || {}
      @namespacing = opts[:namespacing] || opts['namespacing'] || {}
      @page_size = opts[:page_size] || opts['page_size'] || 0
      @icon = opts[:icon] || opts['icon']
    end

    attr_reader :credentials, :namespacing

    def self.load(path = nil)
      path ||= File.join(Dir.pwd, 'zeromcp.config.json')
      return new unless File.exist?(path)

      raw = File.read(path)
      data = JSON.parse(raw)
      new(data)
    rescue JSON::ParserError
      new
    end

    # Resolve an icon config value to a data URI. Supports:
    # - data: URIs (returned as-is)
    # - Local file paths (read and base64 encode)
    # Returns nil on failure or if icon is not set.
    def self.resolve_icon(icon)
      return nil if icon.nil? || icon.empty?
      return icon if icon.start_with?('data:')

      # File path
      path = File.expand_path(icon)
      return nil unless File.exist?(path)

      ext = File.extname(path).downcase
      mime = ICON_MIME[ext] || 'image/png'
      data = File.binread(path)
      "data:#{mime};base64,#{Base64.strict_encode64(data)}"
    rescue => e
      $stderr.puts "[zeromcp] Warning: failed to read icon file #{icon}: #{e.message}"
      nil
    end

    ICON_MIME = {
      '.png'  => 'image/png',
      '.jpg'  => 'image/jpeg',
      '.jpeg' => 'image/jpeg',
      '.gif'  => 'image/gif',
      '.svg'  => 'image/svg+xml',
      '.ico'  => 'image/x-icon',
      '.webp' => 'image/webp'
    }.freeze
  end
end
