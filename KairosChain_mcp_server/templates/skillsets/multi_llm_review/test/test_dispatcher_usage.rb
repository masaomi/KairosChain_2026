# frozen_string_literal: true
# v0.3.1 meta-review bug #2: Dispatcher#build_success preserves `usage`.

require 'minitest/autorun'
require_relative '../lib/multi_llm_review/dispatcher'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      class TestDispatcherUsagePreserved < Minitest::Test
        def test_build_success_preserves_usage_from_llm_response
          d = Dispatcher.new(nil, timeout_seconds: 60, max_concurrent: 1)
          llm_response = {
            'provider' => 'codex',
            'response' => { 'content' => 'ok', 'model' => 'gpt-5.5' },
            'usage' => { 'input_tokens' => 42, 'output_tokens' => 7, 'total_tokens' => 49 }
          }
          result = d.send(:build_success, { role_label: 'r', provider: 'codex' },
                          llm_response,
                          Process.clock_gettime(Process::CLOCK_MONOTONIC))
          assert_equal 42, result[:usage]['input_tokens']
          assert_equal 7,  result[:usage]['output_tokens']
          assert_equal 49, result[:usage]['total_tokens']
        end

        def test_build_success_nil_usage_when_llm_response_lacks
          d = Dispatcher.new(nil, timeout_seconds: 60, max_concurrent: 1)
          llm_response = { 'provider' => 'x', 'response' => { 'content' => 'ok' } }
          result = d.send(:build_success, { role_label: 'r' }, llm_response,
                          Process.clock_gettime(Process::CLOCK_MONOTONIC))
          assert_nil result[:usage]
        end
      end
    end
  end
end
