# frozen_string_literal: true
# The Bedrock client must carry the configured timeout and no SDK retries.
# Before 2026-09-12 it was built with the SDK defaults (60 s read timeout,
# 3 retries): a Tier-1 assessment over a full paper timed out after exactly
# 4 x 60 s and was billed four times. No AWS gem is needed here: the client
# constructor is stubbed and its options captured.

require 'minitest/autorun'
require_relative '../lib/llm_client/adapter'
require_relative '../lib/llm_client/bedrock_adapter'

module KairosMcp
  module SkillSets
    module LlmClient
      class TestBedrockAdapterTimeout < Minitest::Test
        def with_stubbed_client
          captured = nil
          fake = Class.new do
            define_singleton_method(:new) { |**opts| captured = opts; :client }
          end
          had_aws = Object.const_defined?(:Aws)
          Object.const_set(:Aws, Module.new) unless had_aws
          had_ns = Aws.const_defined?(:BedrockRuntime)
          Aws.const_set(:BedrockRuntime, Module.new) unless had_ns
          had_client = Aws::BedrockRuntime.const_defined?(:Client)
          orig = had_client ? Aws::BedrockRuntime.send(:remove_const, :Client) : nil
          Aws::BedrockRuntime.const_set(:Client, fake)
          # `require 'aws-sdk-bedrockruntime'` must not fail when the gem is absent.
          $LOADED_FEATURES << 'aws-sdk-bedrockruntime.rb' unless $LOADED_FEATURES.include?('aws-sdk-bedrockruntime.rb')
          yield
          captured
        ensure
          Aws::BedrockRuntime.send(:remove_const, :Client)
          Aws::BedrockRuntime.const_set(:Client, orig) if orig
          Aws.send(:remove_const, :BedrockRuntime) unless had_ns
          Object.send(:remove_const, :Aws) unless had_aws
        end

        def test_configured_timeout_reaches_the_client_and_retries_are_off
          adapter = BedrockAdapter.new({ 'aws_region' => 'eu-central-1', 'timeout_seconds' => 600 })
          opts = with_stubbed_client { adapter.send(:bedrock_client) }

          assert_equal 'eu-central-1', opts[:region]
          assert_equal 600, opts[:http_read_timeout]
          assert_equal 10, opts[:http_open_timeout]
          assert_equal 0, opts[:retry_limit]
        end

        def test_default_timeout_when_none_configured
          adapter = BedrockAdapter.new({ 'aws_region' => 'eu-central-1' })
          opts = with_stubbed_client { adapter.send(:bedrock_client) }
          assert_equal 120, opts[:http_read_timeout], 'falls back to Adapter#timeout_seconds default'
        end
      end
    end
  end
end
