# frozen_string_literal: true

require 'pathname'

module ZeroMcp
  class Scanner
    attr_reader :tools

    def initialize(config)
      @config = config
      @tools = {}
    end

    def scan
      @tools.clear
      dir = File.expand_path(@config.tools_dir)

      unless Dir.exist?(dir)
        $stderr.puts "[zeromcp] Cannot read tools directory: #{dir}"
        return @tools
      end

      scan_dir(dir, dir)
      @tools
    end

    private

    def scan_dir(dir, root_dir)
      Dir.entries(dir).sort.each do |entry|
        next if entry.start_with?('.')

        full_path = File.join(dir, entry)

        if File.directory?(full_path)
          scan_dir(full_path, root_dir)
        elsif entry.end_with?('.rb')
          load_tool(full_path, root_dir)
        end
      end
    end

    def load_tool(file_path, root_dir)
      name = build_name(file_path, root_dir)

      # Each tool file should return a hash via a special structure.
      # We use a sandboxed binding to evaluate the file.
      tool_def = load_tool_file(file_path)
      return unless tool_def

      log_permissions(name, tool_def[:permissions])

      @tools[name] = Tool.new(
        name: name,
        description: tool_def[:description] || '',
        input: tool_def[:input] || {},
        permissions: tool_def[:permissions] || {}
      ) { |args, ctx| tool_def[:execute].call(args, ctx) }

      $stderr.puts "[zeromcp] Loaded: #{name}"
    rescue => e
      rel = Pathname.new(file_path).relative_path_from(Pathname.new(root_dir))
      $stderr.puts "[zeromcp] Error loading #{rel}: #{e.message}"
    end

    def load_tool_file(file_path)
      loader = ToolLoader.new
      loader.instance_eval(File.read(file_path), file_path)
      loader._tool_definition
    end

    def build_name(file_path, root_dir)
      rel = Pathname.new(file_path).relative_path_from(Pathname.new(root_dir)).to_s
      parts = rel.split('/')
      filename = File.basename(parts.pop, '.rb')

      if parts.length > 0
        dir_prefix = parts[0]
        "#{dir_prefix}#{@config.separator}#{filename}"
      else
        filename
      end
    end

    def log_permissions(name, permissions)
      return unless permissions

      elevated = []
      elevated << "fs: #{permissions[:fs]}" if permissions[:fs]
      elevated << 'exec' if permissions[:exec]
      if elevated.any?
        $stderr.puts "[zeromcp] #{name} requests elevated permissions: #{elevated.join(' | ')}"
      end
    end
  end

  # ToolLoader provides the DSL for tool files
  class ToolLoader
    def initialize
      @definition = {}
    end

    def tool(description: '', permissions: {}, input: {})
      @definition[:description] = description
      @definition[:permissions] = permissions
      @definition[:input] = input
    end

    def execute(&block)
      @definition[:execute] = block
    end

    def _tool_definition
      return nil unless @definition[:execute]
      @definition
    end
  end
end
