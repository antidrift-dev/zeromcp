# frozen_string_literal: true

require 'json'

module ZeroMcp
  class Config
    attr_reader :tools_dir, :separator, :logging, :bypass_permissions

    def initialize(opts = {})
      @tools_dir = opts[:tools_dir] || opts['tools'] || './tools'
      @separator = opts[:separator] || opts['separator'] || '_'
      @logging = opts[:logging] || opts['logging'] || false
      @bypass_permissions = opts[:bypass_permissions] || opts['bypass_permissions'] || false
    end

    def self.load(path = nil)
      path ||= File.join(Dir.pwd, 'zeromcp.config.json')
      return new unless File.exist?(path)

      raw = File.read(path)
      data = JSON.parse(raw)
      new(data)
    rescue JSON::ParserError
      new
    end
  end
end
