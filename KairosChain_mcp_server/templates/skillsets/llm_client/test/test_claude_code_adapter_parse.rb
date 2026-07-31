# frozen_string_literal: true

# What parse_response reads from the CLI envelope, pinned after the
# claude_cli_opus4.6 divergence investigation (2026-07-31).
#
# Four times in the multi_llm_review loop (R6/R8/R10/R13) a slot requesting
# claude-opus-4-6 was answered by claude-haiku-4-5. The record could not say
# why, because this method discarded every diagnostic field the envelope
# carries (modelUsage breakdown, api_error_status, fast_mode_state,
# terminal_reason). The R13 reply's own content settled the observation side
# — it cited identifiers that exist nowhere in the reviewed code — but the
# cause remains open precisely because nothing was kept. These tests hold the
# two fixes: the answering model is chosen by output tokens rather than hash
# order, and the diagnostic fields survive into the response.

require 'minitest/autorun'
require_relative '../lib/llm_client/adapter'
require_relative '../lib/llm_client/claude_code_adapter'

module KairosMcp
  module SkillSets
    module LlmClient
      class TestClaudeCodeAdapterParse < Minitest::Test
        def setup
          @adapter = ClaudeCodeAdapter.new({ 'timeout_seconds' => 30 })
        end

        def parse(payload, requested_model: 'claude-opus-4-6')
          @adapter.send(:parse_response, JSON.generate(payload), requested_model: requested_model)
        end

        def envelope(model_usage:, **extra)
          {
            'type' => 'result', 'is_error' => false, 'result' => 'ok',
            'stop_reason' => 'end_turn',
            'usage' => { 'input_tokens' => 10, 'output_tokens' => 20 },
            'modelUsage' => model_usage
          }.merge(extra)
        end

        def test_a_single_model_envelope_is_that_model
          out = parse(envelope(model_usage: {
            'claude-opus-4-6' => { 'outputTokens' => 116 }
          }))

          assert_equal 'claude-opus-4-6', out['model_observed']
        end

        # The regression the old `keys.first` invited: if the envelope ever
        # carries a second model beside the main call, insertion order must
        # not decide which one "answered". The output tokens do.
        def test_the_answering_model_is_the_one_that_wrote_the_output
          out = parse(envelope(model_usage: {
            'claude-haiku-4-5-20251001' => { 'outputTokens' => 12 },
            'claude-opus-4-6' => { 'outputTokens' => 2048 }
          }))

          assert_equal 'claude-opus-4-6', out['model_observed']
        end

        def test_a_divergent_answer_is_observed_as_itself
          out = parse(envelope(model_usage: {
            'claude-haiku-4-5-20251001' => { 'outputTokens' => 900 }
          }))

          assert_equal 'claude-haiku-4-5-20251001', out['model_observed']
          assert_equal 'claude-opus-4-6', out['model']
          refute_equal out['model'], out['model_observed']
        end

        def test_an_envelope_without_model_usage_observes_nothing
          out = parse(envelope(model_usage: nil))

          assert_nil out['model_observed']
          assert_nil out['model_usage']
          assert_equal 'claude-opus-4-6', out['model']
        end

        def test_the_diagnostic_fields_survive_into_the_response
          out = parse(envelope(
            model_usage: { 'claude-haiku-4-5-20251001' => { 'outputTokens' => 900 } },
            'api_error_status' => 429,
            'fast_mode_state' => 'off',
            'terminal_reason' => 'completed'
          ))

          assert_equal({ 'claude-haiku-4-5-20251001' => { 'outputTokens' => 900 } }, out['model_usage'])
          assert_equal 429, out['api_error_status']
          assert_equal 'off', out['fast_mode_state']
          assert_equal 'completed', out['terminal_reason']
        end

        def test_a_missing_output_tokens_entry_does_not_crash_the_choice
          out = parse(envelope(model_usage: {
            'claude-opus-4-6' => nil,
            'claude-haiku-4-5-20251001' => { 'outputTokens' => 5 }
          }))

          assert_equal 'claude-haiku-4-5-20251001', out['model_observed']
        end
      end
    end
  end
end
