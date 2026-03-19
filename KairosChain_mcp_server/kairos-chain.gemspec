# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'kairos_mcp/version'

Gem::Specification.new do |spec|
  spec.name          = 'kairos-chain'
  spec.version       = KairosMcp::VERSION
  spec.authors       = ['Masa Hatakeyama']
  spec.email         = ['masa@genomicschain.ch']

  spec.summary       = 'KairosChain - Self-referential MCP server for auditable skill self-management'
  spec.description   = <<~DESC
    KairosChain is a Model Context Protocol (MCP) server for self-managed,
    evolvable AI skill definitions. It combines Pure Skills design (Ruby DSL/AST)
    with a private blockchain, enabling AI agents to define, evolve, and audit
    their own capabilities through self-referential skill management.
    Supports stdio and Streamable HTTP transport.
  DESC
  spec.homepage      = 'https://github.com/masaomi/KairosChain_2026'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.0'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri']   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Include library code, executable, templates, and config
  spec.files = Dir[
    'lib/**/*.rb',
    'lib/**/*.erb',     # Admin UI ERB templates
    'bin/*',
    'templates/**/*',
    'templates/**/.*',  # Include .gitkeep files
    'LICENSE',
    'README.md',
    'CHANGELOG.md'
  ]

  spec.bindir        = 'bin'
  spec.executables   = ['kairos-chain', 'kairos_mcp_server']
  spec.require_paths = ['lib']

  # =========================================================================
  # No runtime dependencies (Ruby standard library only for core features)
  # =========================================================================
  #
  # Optional features (install separately):
  #
  #   RAG (Semantic Search):
  #     gem install hnswlib informers
  #
  #   SQLite Storage:
  #     gem install sqlite3
  #
  #   HTTP Transport:
  #     gem install puma rack
  #

  # Development dependencies
  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'rake', '~> 13.0'
end
