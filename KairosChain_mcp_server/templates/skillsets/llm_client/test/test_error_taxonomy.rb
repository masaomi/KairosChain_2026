# frozen_string_literal: true

require_relative '../lib/llm_client/adapter'
require_relative '../lib/llm_client/error_taxonomy'

module KairosMcp
  module SkillSets
    module LlmClient
      module ErrorTaxonomyTest
        PASS = 0
        FAIL = 0

        def self.run
          pass = 0
          fail = 0

          # ---- Pattern matching tests ----

          {
            'HTTP 401 unauthorized' => :auth_error,
            'invalid API key provided' => :auth_error,
            'invalid token xyz' => :auth_error,
            'HTTP 402 billing issue' => :billing_exhausted,
            'payment required' => :billing_exhausted,
            'quota exceeded for this month' => :billing_exhausted,
            'HTTP 429 rate limit' => :rate_limit,
            'rate_limit exceeded' => :rate_limit,
            'too many requests' => :rate_limit,
            'context length exceeded' => :context_overflow,
            'maximum context window' => :context_overflow,
            'message is too long' => :context_overflow,
            'max_tokens exceeded' => :context_overflow,
            'model claude-99 not found' => :model_not_found,
            'model does not exist' => :model_not_found,
            'model is unavailable' => :model_not_found,
            'thinking signature error' => :thinking_error,
            'extended_thinking not supported' => :thinking_error,
            'content filter triggered' => :content_filtered,
            'safety block applied' => :content_filtered,
            'output blocked by policy' => :content_filtered,
            'request timeout' => :timeout,
            'connection timed out' => :timeout,
            'ECONNREFUSED' => :connection_failed,
            'connection refused by host' => :connection_failed,
            'network error detected' => :connection_failed,
            '500 internal server error' => :server_error,
            '502 bad gateway error' => :server_error,
            'internal server error' => :server_error,
            'JSON::ParserError in response' => :parse_error,
            'unexpected token at position 5' => :parse_error,
            'invalid JSON received' => :parse_error,
            'No such file or directory' => :config_error,
            'Permission denied' => :config_error,
            'ENOENT: file missing' => :config_error,
            'EACCES on config' => :config_error,
            'cannot load file' => :config_error,
            'something completely unknown' => :unknown,
          }.each do |message, expected_type|
            result = ErrorTaxonomy.classify(message)
            if result[:type] == expected_type
              pass += 1
              puts "  PASS: classify(\"#{message[0..40]}...\") => #{expected_type}"
            else
              fail += 1
              puts "  FAIL: classify(\"#{message[0..40]}...\") expected #{expected_type}, got #{result[:type]}"
            end
          end

          # ---- Priority tests (first match wins) ----

          # "401 rate limit" should match auth_error (401 is more specific)
          r = ErrorTaxonomy.classify('401 rate limit exceeded')
          if r[:type] == :auth_error
            pass += 1
            puts "  PASS: priority: '401 rate limit' => auth_error (not rate_limit)"
          else
            fail += 1
            puts "  FAIL: priority: '401 rate limit' expected auth_error, got #{r[:type]}"
          end

          # ---- Input format tests ----

          # Hash with 'message' key
          r = ErrorTaxonomy.classify({ 'message' => 'unauthorized access', 'provider' => 'test' })
          if r[:type] == :auth_error
            pass += 1
            puts "  PASS: classify(Hash) => auth_error"
          else
            fail += 1
            puts "  FAIL: classify(Hash) expected auth_error, got #{r[:type]}"
          end

          # Hash with suggested_backoff_seconds
          r = ErrorTaxonomy.classify({ 'message' => 'rate limit', 'suggested_backoff_seconds' => 10 })
          if r[:suggested_backoff] == 10
            pass += 1
            puts "  PASS: classify(Hash) extracts suggested_backoff"
          else
            fail += 1
            puts "  FAIL: classify(Hash) expected suggested_backoff=10, got #{r[:suggested_backoff]}"
          end

          # Hash without 'message' key → .to_s fallback
          r = ErrorTaxonomy.classify({ 'foo' => 'bar' })
          if r[:type] == :unknown
            pass += 1
            puts "  PASS: classify(Hash without message) => unknown"
          else
            fail += 1
            puts "  FAIL: classify(Hash without message) expected unknown, got #{r[:type]}"
          end

          # Empty string
          r = ErrorTaxonomy.classify('')
          if r[:type] == :unknown
            pass += 1
            puts "  PASS: classify('') => unknown"
          else
            fail += 1
            puts "  FAIL: classify('') expected unknown, got #{r[:type]}"
          end

          # ---- CF-5: Typed exception tests ----

          # AuthError
          auth_err = AuthError.new('credentials rejected')
          r = ErrorTaxonomy.classify(auth_err)
          if r[:type] == :auth_error
            pass += 1
            puts "  PASS: classify(AuthError) => auth_error (class-based)"
          else
            fail += 1
            puts "  FAIL: classify(AuthError) expected auth_error, got #{r[:type]}"
          end

          # ApiError with rate_limited
          rate_err = ApiError.new('slow down', rate_limited: true, suggested_backoff: 5)
          r = ErrorTaxonomy.classify(rate_err)
          if r[:type] == :rate_limit && r[:suggested_backoff] == 5
            pass += 1
            puts "  PASS: classify(ApiError rate_limited) => rate_limit with backoff"
          else
            fail += 1
            puts "  FAIL: classify(ApiError rate_limited) expected rate_limit, got #{r[:type]}"
          end

          # CF-4: Errno::ENOENT
          begin
            raise Errno::ENOENT, 'agent.yml'
          rescue => e
            r = ErrorTaxonomy.classify(e)
            if r[:type] == :config_error
              pass += 1
              puts "  PASS: classify(Errno::ENOENT) => config_error (class-based)"
            else
              fail += 1
              puts "  FAIL: classify(Errno::ENOENT) expected config_error, got #{r[:type]}"
            end
          end

          # ---- classify_as_string backward compat ----

          r = ErrorTaxonomy.classify_as_string('unauthorized')
          if r == 'auth_error'
            pass += 1
            puts "  PASS: classify_as_string returns String"
          else
            fail += 1
            puts "  FAIL: classify_as_string expected 'auth_error', got #{r.inspect}"
          end

          # ---- TYPES coverage: all 13 types have retryable + action ----

          ErrorTaxonomy::TYPES.each do |type, meta|
            if meta.key?(:retryable) && meta.key?(:action)
              pass += 1
              puts "  PASS: TYPES[:#{type}] has retryable + action"
            else
              fail += 1
              puts "  FAIL: TYPES[:#{type}] missing keys"
            end
          end

          puts
          puts "=" * 60
          puts "RESULTS: #{pass} passed, #{fail} failed (#{pass + fail} total)"
          puts "=" * 60
          exit(1) if fail > 0
        end
      end
    end
  end
end

KairosMcp::SkillSets::LlmClient::ErrorTaxonomyTest.run
