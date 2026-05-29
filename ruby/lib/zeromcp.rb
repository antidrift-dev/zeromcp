# frozen_string_literal: true

require_relative 'zeromcp/server'

module ZeroMcp
  def self.serve(config_path = nil)
    config = config_path ? Config.load(config_path) : Config.load
    server = Server.new(config)
    server.serve
  end

  def self.serve_http(port: 3000, config_path: nil)
    config = config_path ? Config.load(config_path) : Config.load
    server = Server.new(config)
    server.serve_http(port: port)
  end
end
