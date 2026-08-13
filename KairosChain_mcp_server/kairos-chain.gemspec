# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'kairos_mcp/version'

Gem::Specification.new do |spec|
  spec.name          = 'kairos-chain'
  spec.version       = KairosMcp::VERSION
  spec.authors       = ['Masaomi Hatakeyama']
  spec.email         = ['masaomi.hatakeyama@genomicschain.ch']

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

  # 3.2, not 3.0: the readable_gate Stop hook bounds its scan with
  # Regexp.timeout, which arrived in 3.2. On 3.0 or 3.1 that call raises,
  # the gate's outermost rescue turns it into exit 0, and the operator gets a
  # hook that enforces nothing and says nothing about it. Failing at install
  # is the louder of the two failures. Guarding the call instead was the
  # alternative, and it is worse: without Regexp.timeout there is no
  # per-match bound either, so a declaration carrying many patterns can eat
  # the hook's whole budget and stall the turn.
  spec.required_ruby_version = '>= 3.2'

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
  ].reject { |p| p.include?('__pycache__') || p.end_with?('.pyc') }
  # The globs above walk the filesystem rather than asking git, so anything a
  # tool leaves behind under templates/ ships. Running a Python script in
  # templates/knowledge/*/scripts/ writes bytecode next to it, which is both
  # useless to a consumer and stale the moment the source changes.

  spec.bindir        = 'bin'
  # Every file under bin/ that a hook or an operator invokes by name must be
  # listed here, or the `bin/*` glob above ships it without putting it on PATH.
  # kairos-plugin-project was missing until 2026-08-12, and was committed
  # non-executable besides: the two PostToolUse hooks calling it had been
  # failing with "command not found" on every fire, silently, because a hook
  # that cannot start reports nothing.
  spec.executables   = %w[
    kairos-chain
    kairos_mcp_server
    kairos-plugin-project
    kairos-readable-gate
  ]
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
