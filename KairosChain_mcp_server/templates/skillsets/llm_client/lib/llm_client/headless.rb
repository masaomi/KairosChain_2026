# frozen_string_literal: true

require 'yaml'
require_relative 'call_router'

module KairosMcp
  module SkillSets
    module LlmClient
      # Non-MCP entry point to the llm_client adapters. Used by the detached
      # worker in multi_llm_review v0.3.0 (Phase 11.5) to invoke llm_call
      # without MCP ToolRegistry or BaseTool dependencies.
      #
      # Loads only what's needed: CallRouter + the YAML config file.
      # Adapter classes are lazy-loaded by CallRouter.build_adapter.
      class Headless
        CONFIG_RELATIVE_PATH = '../../config/llm_client.yml'

        # Sensible default matches LlmCall#load_config's built-in fallback,
        # so a worker that somehow loses access to llm_client.yml still has
        # a usable provider (subject to ANTHROPIC_API_KEY availability).
        DEFAULT_CONFIG = {
          'provider' => 'anthropic',
          'model' => 'claude-sonnet-4-6',
          'api_key_env' => 'ANTHROPIC_API_KEY'
        }.freeze

        def initialize(config: nil)
          loaded = config || load_config_from_disk
          # Normalize to string keys so YAML-with-symbols and YAML-with-strings
          # both work and so `@config['provider'].nil?` guard is reliable
          # (R2-impl P2 from claude_cli_opus4.6).
          @config = loaded.is_a?(Hash) ? loaded.transform_keys(&:to_s) : {}
          # If config has no provider (empty Hash from missing file, or
          # config argument was nil/junk) fall back to LlmCall-parity defaults.
          @config = DEFAULT_CONFIG.merge(@config) if @config['provider'].nil?
        end

        # Matches the Dispatcher#dispatch caller contract (invoker.invoke_tool).
        # Returns the same text_content array shape LlmCall#call would return.
        #
        # Currently supports only 'llm_call'. llm_status / llm_configure are
        # future extensions (§5.5 Headless widening). Raising ArgumentError
        # (not NotImplementedError) so Dispatcher's existing rescue treats it
        # as a per-reviewer error without crashing the whole worker.
        def invoke_tool(name, args, context: nil)
          unless name == 'llm_call'
            raise ArgumentError, "Headless supports only 'llm_call', got: #{name.inspect}"
          end
          # MainState bracket so the worker's pulse thread sees in-call
          # activity as "alive" during long adapter.call blocks. Without
          # this, worker.tick ages past 30s on any single reviewer > 30s,
          # and Phase 2 would falsely declare heartbeat_stale (R1-impl P0
          # from codex 5.5 + cursor).
          # Guarded by `defined?` so non-worker consumers (MCP direct call)
          # that never load multi_llm_review/main_state don't NameError.
          bracket = defined?(KairosMcp::SkillSets::MultiLlmReview::MainState)
          if bracket
            KairosMcp::SkillSets::MultiLlmReview::MainState.enter_call!
          end
          begin
            result = CallRouter.perform(args, @config)
          ensure
            if bracket
              KairosMcp::SkillSets::MultiLlmReview::MainState.exit_call!
            end
          end
          # Shape matches BaseTool#text_content (symbol :text key) — what
          # Dispatcher consumes today via `b[:text] || b['text']`.
          [{ text: JSON.generate(result) }]
        end

        # Expose the config shallowly (for tests / debugging).
        attr_reader :config

        private

        def load_config_from_disk
          path = File.expand_path(CONFIG_RELATIVE_PATH, __dir__)
          return {} unless File.exist?(path)
          YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {}
        end
      end
    end
  end
end
