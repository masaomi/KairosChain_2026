# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module KairosMcp
  class Daemon
    # DaemonLlmCaller — thin Anthropic API wrapper for daemon LLM phases.
    #
    # Design (Phase 4 v0.3 §1.3):
    #   Interface contract (LlmPhaseFunctions expects):
    #     caller.call(messages:, system:, max_tokens:, **) → Hash
    #     Return: { content: String, input_tokens: Int, output_tokens: Int,
    #               attempts: Int }
    #
    #   Usage tracking contract:
    #     `attempts` reports TOTAL HTTP requests made (including retries).
    #     `input_tokens` / `output_tokens` are from the SUCCESSFUL response only.
    #     UsageAccumulator records `attempts` as llm_calls (not 1).
    #
    #   Shutdown contract:
    #     Caller injects `stop_requested:` proc. DaemonLlmCaller checks it
    #     between retry sleeps and before each HTTP call.
    class DaemonLlmCaller
      API_URL     = 'https://api.anthropic.com/v1/messages'
      API_VERSION = '2023-06-01'
      DEFAULT_MODEL   = 'claude-sonnet-4-6-20260514'
      DEFAULT_TIMEOUT = 5   # short for SIGTERM compliance (<10s)
      MAX_RETRIES     = 2
      MAX_RETRY_SLEEP = 30  # fallback cap when no Retry-After header

      class LlmCallError < StandardError
        attr_reader :http_code, :retryable, :retry_after, :attempts

        def initialize(msg, http_code: nil, retryable: false, retry_after: nil, attempts: 0)
          super(msg)
          @http_code   = http_code
          @retryable   = retryable
          @retry_after = retry_after
          @attempts    = attempts
        end
      end

      class ConfigError < StandardError; end
      class ShutdownRequested < StandardError; end

      # @param api_key [String] Anthropic API key
      # @param model [String] model ID (dated)
      # @param timeout [Integer] HTTP read timeout in seconds
      # @param stop_requested [Proc] returns true when daemon is shutting down
      # @param heartbeat_callback [Proc, nil] called every 0.5s during retry sleep
      # @param logger [#info, #warn, #error, nil]
      def initialize(
        api_key:,
        model: DEFAULT_MODEL,
        timeout: DEFAULT_TIMEOUT,
        stop_requested: -> { false },
        heartbeat_callback: nil,
        logger: nil
      )
        @api_key            = api_key
        @model              = model
        @timeout            = timeout
        @stop_requested     = stop_requested
        @heartbeat_callback = heartbeat_callback
        @logger             = logger
        validate_config!
      end

      # @param messages [Array<Hash>] Anthropic message format
      # @param system [String] system prompt
      # @param max_tokens [Integer]
      # @return [Hash] { content:, input_tokens:, output_tokens:, attempts: }
      # @raise [LlmCallError] after retries exhausted
      # @raise [ShutdownRequested] if stop_requested returns true
      def call(messages:, system:, max_tokens:, **)
        attempts = 0
        last_error = nil

        (1 + MAX_RETRIES).times do |i|
          check_shutdown!

          attempts += 1
          call_start = monotonic_now

          begin
            response = http_post(
              model: @model,
              max_tokens: max_tokens,
              system: system,
              messages: messages
            )

            log_call(:info, attempts, call_start, response)

            return {
              content:      extract_text(response),
              input_tokens:  response.dig('usage', 'input_tokens') || 0,
              output_tokens: response.dig('usage', 'output_tokens') || 0,
              attempts:      attempts
            }

          rescue LlmCallError => e
            last_error = e
            log(:warn, "LLM call failed: HTTP #{e.http_code} (attempt #{i + 1}/#{1 + MAX_RETRIES})")

            if e.retryable && i < MAX_RETRIES
              sleep_time = compute_backoff(i, e)
              log(:info, "Retrying after #{sleep_time}s")
              interruptible_sleep(sleep_time)
            else
              break
            end
          end
        end

        # Attach total attempt count to the error for budget tracking
        if last_error
          last_error.instance_variable_set(:@attempts, attempts) unless last_error.attempts > 0
          raise last_error
        end
        raise LlmCallError.new('unknown error', attempts: attempts)
      end

      # Startup probe: verify API key is valid.
      # @raise [ConfigError] if key is invalid or API unreachable
      def verify!
        call(
          messages: [{ role: 'user', content: 'ping' }],
          system: 'Reply with exactly "pong".',
          max_tokens: 8
        )
        true
      rescue LlmCallError => e
        raise ConfigError, "API key verification failed: #{e.message}"
      rescue ShutdownRequested
        # Shutdown during verify is fine — don't mask as ConfigError
        raise
      end

      private

      def validate_config!
        raise ConfigError, 'ANTHROPIC_API_KEY is required' if @api_key.nil? || @api_key.empty?
      end

      def check_shutdown!
        raise ShutdownRequested, 'stop requested' if @stop_requested.call
      end

      def http_post(body)
        uri = URI(API_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = @timeout
        http.open_timeout = @timeout

        req = Net::HTTP::Post.new(uri.path)
        req['content-type']      = 'application/json'
        req['x-api-key']         = @api_key
        req['anthropic-version'] = API_VERSION
        req.body = JSON.generate(body)

        resp = http.request(req)
        code = resp.code.to_i

        case code
        when 200
          JSON.parse(resp.body)
        when 429, 529
          retry_after = resp['retry-after']&.to_i
          raise LlmCallError.new(
            "HTTP #{code}: rate limited",
            http_code: code,
            retryable: true,
            retry_after: retry_after
          )
        when 401, 403
          raise LlmCallError.new(
            "HTTP #{code}: authentication failed",
            http_code: code
          )
        when 400
          raise LlmCallError.new(
            "HTTP #{code}: bad request — #{resp.body[0..200]}",
            http_code: code
          )
        when 500..599
          raise LlmCallError.new(
            "HTTP #{code}: server error",
            http_code: code,
            retryable: true
          )
        else
          raise LlmCallError.new(
            "HTTP #{code}: #{resp.body[0..200]}",
            http_code: code
          )
        end
      end

      # Interruptible sleep: checks stop_requested and emits heartbeat every 0.5s.
      def interruptible_sleep(seconds)
        slept = 0.0
        while slept < seconds
          check_shutdown!
          @heartbeat_callback&.call
          step = [0.5, seconds - slept].min
          sleep(step)
          slept += step
        end
      end

      # Honor Retry-After header when present; otherwise exponential backoff.
      def compute_backoff(attempt, error)
        if error.retry_after && error.retry_after > 0
          error.retry_after  # trust the API — no cap (interruptible_sleep handles shutdown)
        else
          [2 ** (attempt + 1), MAX_RETRY_SLEEP].min
        end
      end

      def extract_text(response)
        blocks = response['content'] || []
        blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join
      end

      def log_call(level, attempts, call_start, response)
        duration_ms = ((monotonic_now - call_start) * 1000).round
        log(level, JSON.generate({
          event:         'llm_call',
          model:         @model,
          attempts:      attempts,
          input_tokens:  response.dig('usage', 'input_tokens'),
          output_tokens: response.dig('usage', 'output_tokens'),
          duration_ms:   duration_ms
        }))
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def log(level, msg)
        return unless @logger
        @logger.public_send(level, msg)
      rescue StandardError
        # never crash on logging
      end
    end
  end
end
