# frozen_string_literal: true

require_relative 'zeromcp/server'
require_relative 'zeromcp/remote'
require_relative 'zeromcp/registry'

module ZeroMcp
  def self.serve(config_path = nil)
    config = config_path ? Config.load(config_path) : Config.load
    server = Server.new(config)
    server.serve
  end
end
