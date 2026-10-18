# frozen_string_literal: true
# llm_call reports the model ID it asked for beside the one the provider
# answered with. On Bedrock they differ — eu.anthropic.claude-sonnet-5-5 is
# sent, claude-sonnet-5-5 comes back — and only the first names the inference
# profile, so a caller recording provenance (gc_tier1_assess's report) could
# not tell which region profile served the call.

require 'minitest/autorun'
require 'json'
$LOAD_PATH.unshift File.expand_path('../../../../lib', __dir__)
require 'kairos_mcp/tools/base_tool'
require_relative '../tools/llm_call'

module KairosMcp
  module SkillSets
    module LlmClient
      class TestLlmCallRequestedModel < Minitest::Test
        class Answering
          def call(**_kwargs)
            { 'content' => '{}', 'stop_reason' => 'end_turn', 'model' => 'claude-sonnet-5-5',
              'input_tokens' => 1, 'output_tokens' => 1 }
          end
        end

        class Stubbed < Tools::LlmCall
          def initialize(config)
            super()
            @config = config
          end

          private

          def load_config = @config.dup
          def build_adapter(_config) = Answering.new
        end

        def payload(config, arguments = {})
          out = Stubbed.new(config).call({ 'messages' => [{ 'role' => 'user', 'content' => 'hi' }] }.merge(arguments))
          JSON.parse(out.first[:text])
        end

        def test_the_configured_id_is_reported_beside_the_answering_model
          got = payload('provider' => 'bedrock', 'model' => 'eu.anthropic.claude-sonnet-5-5')
          assert_equal 'ok', got['status']
          assert_equal 'claude-sonnet-5-5', got['model']
          assert_equal 'eu.anthropic.claude-sonnet-5-5', got['requested_model']
        end

        def test_a_per_call_model_override_is_what_is_reported
          got = payload({ 'provider' => 'bedrock', 'model' => 'eu.anthropic.claude-sonnet-5-5' },
                        'model' => 'eu.anthropic.claude-opus-5-5')
          assert_equal 'eu.anthropic.claude-opus-5-5', got['requested_model']
        end
      end
    end
  end
end
