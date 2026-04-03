# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = 'zeromcp'
  s.version     = '0.1.0'
  s.summary     = 'Zero-config MCP runtime'
  s.description = 'Drop tool files in a directory, get a working MCP server. Zero boilerplate.'
  s.authors     = ['Antidrift']
  s.email       = 'hello@antidrift.io'
  s.homepage    = 'https://github.com/probeo-io/zeromcp'
  s.license     = 'MIT'

  s.required_ruby_version = '>= 3.0.0'

  s.files = Dir['lib/**/*.rb'] + ['zeromcp.gemspec', 'Gemfile', 'README.md']
  s.executables = ['zeromcp']
  s.require_paths = ['lib']
end
