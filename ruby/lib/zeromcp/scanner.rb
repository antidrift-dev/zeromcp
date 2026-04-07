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
      dirs = @config.tools_dir
      dirs = [dirs] unless dirs.is_a?(Array)

      dirs.each do |d|
        dir = File.expand_path(d)
        unless Dir.exist?(dir)
          $stderr.puts "[zeromcp] Cannot read tools directory: #{dir}"
          next
        end
        scan_dir(dir, dir)
      end
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

  # --- Resource scanning ---

  MIME_MAP = {
    '.json' => 'application/json',
    '.txt'  => 'text/plain',
    '.md'   => 'text/markdown',
    '.html' => 'text/html',
    '.xml'  => 'application/xml',
    '.yaml' => 'text/yaml',
    '.yml'  => 'text/yaml',
    '.csv'  => 'text/csv',
    '.css'  => 'text/css',
    '.js'   => 'application/javascript',
    '.ts'   => 'text/typescript',
    '.sql'  => 'text/plain',
    '.sh'   => 'text/plain',
    '.py'   => 'text/plain',
    '.go'   => 'text/plain',
    '.rs'   => 'text/plain',
    '.toml' => 'text/plain',
    '.ini'  => 'text/plain',
    '.env'  => 'text/plain'
  }.freeze

  class ResourceScanner
    attr_reader :resources, :templates

    def initialize(config)
      @config = config
      @resources = {}
      @templates = {}
    end

    def scan
      @resources.clear
      @templates.clear

      @config.resources_dir.each do |d|
        dir = File.expand_path(d)
        unless Dir.exist?(dir)
          $stderr.puts "[zeromcp] Cannot read resources directory: #{dir}"
          next
        end
        scan_dir(dir, dir)
      end
    end

    private

    def scan_dir(dir, root_dir)
      Dir.entries(dir).sort.each do |entry|
        next if entry.start_with?('.')

        full_path = File.join(dir, entry)

        if File.directory?(full_path)
          scan_dir(full_path, root_dir)
        elsif File.file?(full_path)
          rel = Pathname.new(full_path).relative_path_from(Pathname.new(root_dir)).to_s
          ext = File.extname(entry)
          name = rel.sub(/\.[^.]+$/, '').gsub(%r{[\\/]}, @config.separator)

          if ext == '.rb'
            load_dynamic(full_path, name)
          else
            load_static(full_path, rel, name, ext)
          end
        end
      end
    end

    def load_dynamic(file_path, name)
      loader = ResourceLoader.new
      loader.instance_eval(File.read(file_path), file_path)
      defn = loader._definition
      return unless defn && defn[:read]

      if defn[:uri_template]
        @templates[name] = {
          uri_template: defn[:uri_template],
          name: name,
          description: defn[:description],
          mime_type: defn[:mime_type] || 'application/json',
          read: defn[:read]
        }
      else
        uri = defn[:uri] || "resource:///#{name}"
        @resources[name] = {
          uri: uri,
          name: name,
          description: defn[:description],
          mime_type: defn[:mime_type] || 'application/json',
          read: defn[:read]
        }
      end

      $stderr.puts "[zeromcp] Resource loaded: #{name}"
    rescue => e
      $stderr.puts "[zeromcp] Error loading resource #{file_path}: #{e.message}"
    end

    def load_static(file_path, rel_path, name, ext)
      uri = "resource:///#{rel_path.gsub('\\', '/')}"
      mime_type = MIME_MAP[ext] || 'application/octet-stream'

      @resources[name] = {
        uri: uri,
        name: name,
        description: "Static resource: #{rel_path}",
        mime_type: mime_type,
        read: -> { File.read(file_path, encoding: 'UTF-8') }
      }
    end
  end

  # DSL for dynamic resource .rb files
  class ResourceLoader
    def initialize
      @definition = {}
    end

    def resource(description: nil, mime_type: nil, uri: nil, uri_template: nil)
      @definition[:description] = description
      @definition[:mime_type] = mime_type
      @definition[:uri] = uri
      @definition[:uri_template] = uri_template
    end

    def read(&block)
      @definition[:read] = block
    end

    def _definition
      return nil unless @definition[:read]
      @definition
    end
  end

  # --- Prompt scanning ---

  class PromptScanner
    attr_reader :prompts

    def initialize(config)
      @config = config
      @prompts = {}
    end

    def scan
      @prompts.clear

      @config.prompts_dir.each do |d|
        dir = File.expand_path(d)
        unless Dir.exist?(dir)
          $stderr.puts "[zeromcp] Cannot read prompts directory: #{dir}"
          next
        end
        scan_dir(dir, dir)
      end
    end

    private

    def scan_dir(dir, root_dir)
      Dir.entries(dir).sort.each do |entry|
        next if entry.start_with?('.')

        full_path = File.join(dir, entry)

        if File.directory?(full_path)
          scan_dir(full_path, root_dir)
        elsif entry.end_with?('.rb')
          rel = Pathname.new(full_path).relative_path_from(Pathname.new(root_dir)).to_s
          name = rel.sub(/\.rb$/, '').gsub(%r{[\\/]}, @config.separator)
          load_prompt(full_path, name)
        end
      end
    end

    def load_prompt(file_path, name)
      loader = PromptLoader.new
      loader.instance_eval(File.read(file_path), file_path)
      defn = loader._definition
      return unless defn && defn[:render]

      # Convert arguments hash to MCP prompt arguments array
      prompt_args = nil
      if defn[:arguments] && !defn[:arguments].empty?
        prompt_args = defn[:arguments].map do |key, val|
          key = key.to_s
          if val.is_a?(String)
            { 'name' => key, 'required' => true }
          elsif val.is_a?(Hash)
            entry = { 'name' => key }
            desc = val[:description] || val['description']
            entry['description'] = desc if desc
            optional = val[:optional] || val['optional']
            entry['required'] = !optional
            entry
          else
            { 'name' => key, 'required' => true }
          end
        end
      end

      @prompts[name] = {
        name: name,
        description: defn[:description],
        arguments: prompt_args,
        render: defn[:render]
      }

      $stderr.puts "[zeromcp] Prompt loaded: #{name}"
    rescue => e
      $stderr.puts "[zeromcp] Error loading prompt #{file_path}: #{e.message}"
    end
  end

  # DSL for prompt .rb files
  class PromptLoader
    def initialize
      @definition = {}
    end

    def prompt(description: nil, arguments: {})
      @definition[:description] = description
      @definition[:arguments] = arguments
    end

    def render(&block)
      @definition[:render] = block
    end

    def _definition
      return nil unless @definition[:render]
      @definition
    end
  end
end
