# frozen_string_literal: true

require 'json'
require 'base64'
require 'net/http'
require 'uri'

module ZeroMcp
  class Config
    attr_reader :tools_dir, :tool_sources, :resources_dir, :prompts_dir,
                :separator, :logging, :bypass_permissions, :execute_timeout,
                :page_size, :icon, :title, :remote, :autoload_tools, :transport

    def initialize(opts = {})
      tools = opts[:tools_dir] || opts['tools'] || './tools'
      @tool_sources = Config.resolve_sources(tools)
      @tools_dir = @tool_sources.map { |s| s['path'] }

      resources = opts[:resources_dir] || opts['resources']
      @resources_dir = resources ? Config.resolve_sources(resources).map { |s| s['path'] } : []

      prompts = opts[:prompts_dir] || opts['prompts']
      @prompts_dir = prompts ? Config.resolve_sources(prompts).map { |s| s['path'] } : []

      @separator = opts[:separator] || opts['separator'] || '_'
      @logging = opts[:logging] || opts['logging'] || false
      @bypass_permissions = opts[:bypass_permissions] || opts['bypass_permissions'] || false
      @execute_timeout = opts[:execute_timeout] || opts['execute_timeout'] || 30 # seconds
      @credentials = opts[:credentials] || opts['credentials'] || {}
      @cache_credentials = opts.key?(:cache_credentials) ? opts[:cache_credentials] : (opts.key?('cache_credentials') ? opts['cache_credentials'] : true)
      @namespacing = opts[:namespacing] || opts['namespacing'] || {}
      @page_size = opts[:page_size] || opts['page_size'] || 0
      @icon = opts[:icon] || opts['icon']
      @title = opts[:title] || opts['title'] || 'ZeroMCP'
      @remote = opts[:remote] || opts['remote'] || []
      @autoload_tools = opts[:autoload_tools] || opts['autoload_tools'] || false
      @transport = opts[:transport] || opts['transport']
    end

    attr_reader :credentials, :cache_credentials, :namespacing

    def self.load(path = nil)
      path ||= File.join(Dir.pwd, 'zeromcp.config.json')
      return new unless File.exist?(path)

      raw = File.read(path)
      data = JSON.parse(raw)
      new(data)
    rescue JSON::ParserError
      new
    end

    # Normalize a `tools` / `resources` / `prompts` value (a string, or an
    # array of strings and { 'path' => ..., 'prefix' => ... } hashes) to an
    # array of { 'path' => String, 'prefix' => String|nil }.
    def self.resolve_sources(value)
      list = value.is_a?(Array) ? value : [value]
      list.map do |entry|
        if entry.is_a?(Hash)
          { 'path' => entry['path'] || entry[:path], 'prefix' => entry['prefix'] || entry[:prefix] }
        else
          { 'path' => entry, 'prefix' => nil }
        end
      end
    end

    # True when `transport` asks for the removed built-in HTTP server: the
    # string "http", a { 'type' => 'http' } hash, or an array containing either.
    def http_transport?
      list = @transport.is_a?(Array) ? @transport : [@transport]
      list.any? do |t|
        type = t.is_a?(Hash) ? (t['type'] || t[:type]) : t
        type.to_s == 'http'
      end
    end

    # Resolve an auth value: "env:VAR" reads ENV[VAR] (warning when unset),
    # anything else is returned as-is. nil passes through.
    def self.resolve_auth(auth)
      return nil if auth.nil?

      if auth.start_with?('env:')
        var = auth[4..]
        val = ENV[var]
        $stderr.puts "[zeromcp] Warning: environment variable #{var} not set" if val.nil?
        return val
      end
      auth
    end

    # Resolve an icon config value to a data URI. Supports:
    # - data: URIs (returned as-is)
    # - http(s) URLs (fetched and base64 encoded)
    # - Local file paths (read and base64 encode)
    # Returns nil on failure or if icon is not set.
    def self.resolve_icon(icon)
      return nil if icon.nil? || icon.empty?
      return icon if icon.start_with?('data:')
      return fetch_icon(icon) if icon.start_with?('http://', 'https://')

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

    def self.fetch_icon(url)
      res = Net::HTTP.get_response(URI(url))
      unless res.is_a?(Net::HTTPSuccess)
        $stderr.puts "[zeromcp] Warning: failed to fetch icon #{url}: #{res.code}"
        return nil
      end
      content_type = res['content-type'] || 'image/png'
      "data:#{content_type};base64,#{Base64.strict_encode64(res.body || '')}"
    rescue => e
      $stderr.puts "[zeromcp] Warning: failed to fetch icon #{url}: #{e.message}"
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
