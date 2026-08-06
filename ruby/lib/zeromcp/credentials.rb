# frozen_string_literal: true

require 'json'

module ZeroMcp
  module Credentials
    module_function

    def resolve(tool_name, config, cache: nil)
      return nil if config.credentials.empty?
      config.credentials.each do |ns, source|
        if tool_name.start_with?("#{ns}_") || tool_name.start_with?("#{ns}#{config.separator}")
          return resolve_for_ns(ns.to_s, source, config, cache)
        end
      end
      nil
    end

    def resolve_for_ns(ns, source, config, cache)
      return resolve_source(source) unless config.cache_credentials
      return cache[ns] if cache && cache.key?(ns)
      creds = resolve_source(source)
      cache[ns] = creds if cache
      creds
    end

    def resolve_source(source)
      source = source.transform_keys(&:to_s) if source.is_a?(Hash)
      if source['env']
        val = ENV[source['env']]
        return nil if val.nil? || val.empty?
        begin; return JSON.parse(val); rescue; return val; end
      end
      if source['file']
        path = File.expand_path(source['file'])
        return nil unless File.exist?(path)
        val = File.read(path).strip
        begin; return JSON.parse(val); rescue; return val; end
      end
      nil
    end
  end
end
