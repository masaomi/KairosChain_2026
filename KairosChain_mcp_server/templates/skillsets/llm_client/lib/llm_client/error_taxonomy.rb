# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module LlmClient
      # Error classification for LLM API responses.
      # 13 error types with regex-based pattern matching (specific → general).
      # Designed for cognitive_loop.rb's call_llm_with_fallback to take
      # type-appropriate recovery actions (retry, backoff, switch, compress).
      module ErrorTaxonomy
        TYPES = {
          auth_error:        { retryable: false, action: :switch_provider },
          rate_limit:        { retryable: true,  action: :backoff },
          context_overflow:  { retryable: false, action: :compress },
          billing_exhausted: { retryable: false, action: :switch_provider },
          model_not_found:   { retryable: false, action: :fallback_model },
          timeout:           { retryable: true,  action: :retry },
          connection_failed: { retryable: true,  action: :retry },
          server_error:      { retryable: true,  action: :retry },
          parse_error:       { retryable: true,  action: :retry },
          content_filtered:  { retryable: false, action: :rephrase },
          thinking_error:    { retryable: true,  action: :disable_thinking },
          config_error:      { retryable: false, action: :report },
          unknown:           { retryable: false, action: :report },
        }.freeze

        # Patterns ordered specific → general. HTTP status codes use \b boundary.
        PATTERNS = [
          { match: /\b401\b|unauthorized|invalid.{0,20}key|invalid.{0,20}token/i,
            type: :auth_error },
          { match: /\b402\b|billing|payment|quota\s*exceeded/i,
            type: :billing_exhausted },
          { match: /\b429\b|rate.?limit|too many requests/i,
            type: :rate_limit },
          { match: /context.?(length|window|limit)|too.?long|max.?tokens?\s*exceeded/i,
            type: :context_overflow },
          { match: /model.*not.*found|does not exist|model.*unavailable/i,
            type: :model_not_found },
          { match: /thinking.*signature|extended_thinking/i,
            type: :thinking_error },
          { match: /content.?filter|safety.*block|output.*blocked/i,
            type: :content_filtered },
          { match: /timeout|timed?\s*out/i,
            type: :timeout },
          { match: /ECONNREFUSED|connection\s*(refused|failed|reset)|network\s*error/i,
            type: :connection_failed },
          { match: /\b5\d{2}\b.*(?:error|fail)|internal\s+server\s+error|server\s+error/i,
            type: :server_error },
          { match: /JSON::ParserError|unexpected\s+token|invalid\s+JSON|malformed\s+JSON/i,
            type: :parse_error },
          { match: /No such file or directory|Permission denied|ENOENT|EACCES|cannot\s+load|LoadError|configuration.{0,20}(?:missing|invalid)/i,
            type: :config_error },
        ].freeze

        # Classify an error into one of the 13 types.
        # Accepts String, Hash (with 'message' key), or any object with #message.
        # Returns Hash with :type, :retryable, :action, :original_message,
        # and optionally :suggested_backoff.
        #
        # CF-4/CF-5 fix: class-based pre-check for typed exceptions before regex.
        def self.classify(error)
          # CF-5: Honor typed exception metadata before regex matching.
          type = classify_by_type(error)
          message = extract_message(error)

          # CF-4: Fall through to regex only if class-based check didn't match.
          unless type
            matched = PATTERNS.find { |p| p[:match].match?(message) }
            type = matched ? matched[:type] : :unknown
          end

          result = { type: type, **TYPES[type], original_message: message }

          if error.respond_to?(:suggested_backoff) && error.suggested_backoff
            result[:suggested_backoff] = error.suggested_backoff
          elsif error.is_a?(Hash) && error['suggested_backoff_seconds']
            result[:suggested_backoff] = error['suggested_backoff_seconds']
          end

          result
        end

        # CF-5: Class-based type detection for typed exceptions.
        # Returns type symbol or nil (fall through to regex).
        def self.classify_by_type(error)
          return nil if error.is_a?(String) || error.is_a?(Hash)

          # AuthError (subclass of ApiError) — always auth_error
          if defined?(::KairosMcp::SkillSets::LlmClient::AuthError) &&
             error.is_a?(::KairosMcp::SkillSets::LlmClient::AuthError)
            return :auth_error
          end

          # ApiError with rate_limited flag
          if error.respond_to?(:rate_limited) && error.rate_limited
            return :rate_limit
          end

          # CF-4: File-system errors → config_error
          return :config_error if error.is_a?(Errno::ENOENT) || error.is_a?(Errno::EACCES)
          return :config_error if error.is_a?(LoadError)

          nil
        end
        private_class_method :classify_by_type

        def self.extract_message(error)
          case error
          when String then error
          when Hash   then error['message'] || error.to_s
          else error.respond_to?(:message) ? error.message : error.to_s
          end
        end
        private_class_method :extract_message

        # Backward-compatible wrapper returning type as String.
        # Drop-in replacement for llm_call.rb's old classify_error.
        def self.classify_as_string(error)
          classify(error)[:type].to_s
        end
      end
    end
  end
end
