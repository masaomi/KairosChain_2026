# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Agent
      module NativeBody
        # SpendMeter — NB-5 in-body ceilings (native body design v0.6 FROZEN).
        #
        # Spend and step count are enforced in-body (this class); wall-clock
        # and output volume are enforced boundary-side by the driver's
        # timeout/output caps, which are the outer backstop. Everything here
        # fails closed:
        # - the per-call spend bound covers BOTH axes: a request's spend is
        #   its input (the prompt, pre-estimated by a tokenizer heuristic)
        #   plus its output (the request's max-output). A request whose
        #   estimate exceeds the remaining budget is refused BEFORE it is
        #   sent — post-hoc cumulative checking alone cannot bound
        #   single-call overshoot (R4/R5 terminal finding).
        # - missing usage data halts (unmeasurable spend never under-counts
        #   to zero — do NOT reproduce call_router's nil→0 coercion).
        class SpendMeter
          # Ceiling breach: termination and a non-success outcome, never
          # silent truncation into apparent success (NB-5).
          class CeilingHalt < StandardError
            attr_reader :kind

            def initialize(kind, message)
              @kind = kind
              super(message)
            end
          end

          # The per-call bound must be a true UPPER bound on real input
          # tokens, or single-call overshoot slips through. History:
          #   R1 F1: chars/4 is a typical-case heuristic, not an upper bound.
          #   R2 G1: chars (1 token/char) is ALSO not an upper bound — the
          #   tokenizers Claude/GPT use are byte-level BPE over UTF-8, so a
          #   multibyte character (a CJK glyph or emoji, 3–4 bytes) can emit
          #   2–4 tokens; num_tokens ≤ num_chars is FALSE for such text
          #   (verified: 系統的… 27 chars → 33 tokens). The sound, tokenizer-
          #   free upper bound is the BYTE count: a byte-level BPE token
          #   merges one OR MORE bytes, so num_tokens ≤ num_bytes ALWAYS.
          # Callers therefore pass the prompt's BYTE length. For ASCII
          # bytes == chars (English unaffected); for CJK it is ~3× more
          # conservative — the fail-closed direction the guard wants.
          BYTES_PER_TOKEN = 1

          attr_reader :spent_input_tokens, :spent_output_tokens, :steps_taken, :max_spend_tokens, :max_steps

          def initialize(max_spend_tokens:, max_steps:)
            @max_spend_tokens = Integer(max_spend_tokens)
            @max_steps = Integer(max_steps)
            raise ArgumentError, 'ceilings must be positive (NB-5 fail-closed)' if @max_spend_tokens <= 0 || @max_steps <= 0

            @spent_input_tokens = 0
            @spent_output_tokens = 0
            @steps_taken = 0
          end

          def remaining_tokens
            @max_spend_tokens - @spent_input_tokens - @spent_output_tokens
          end

          def step!
            @steps_taken += 1
            return unless @steps_taken > @max_steps

            raise CeilingHalt.new(:steps, "step ceiling reached: #{@steps_taken} > #{@max_steps}")
          end

          # Upper bound on input tokens from the prompt's BYTE length (see
          # BYTES_PER_TOKEN): a byte-level BPE token merges one or more bytes,
          # so this never returns below the real token count. Callers MUST
          # pass bytes (String#bytesize), not characters.
          def estimate_input_tokens(prompt_bytes)
            (Integer(prompt_bytes) + BYTES_PER_TOKEN - 1) / BYTES_PER_TOKEN
          end

          # Per-call spend bound (both axes), evaluated BEFORE the request is
          # sent. `prompt_bytes` is the byte length of the exact payload sent
          # to the provider. Refusal halts the loop: the loop's context only
          # grows, so a call that cannot fit now will not fit later.
          def assert_call!(prompt_bytes:, max_output_tokens:)
            input_est = estimate_input_tokens(prompt_bytes)
            output_bound = Integer(max_output_tokens)
            raise ArgumentError, 'max_output_tokens must be positive (per-call bound needs a real output axis)' if output_bound <= 0

            estimated = input_est + output_bound
            return if estimated <= remaining_tokens

            raise CeilingHalt.new(
              :per_call_overshoot,
              "per-call spend bound refused the request before send: estimated #{estimated} tokens " \
              "(input ~#{input_est} + max-output #{output_bound}) > remaining #{remaining_tokens} (NB-5)"
            )
          end

          # Post-hoc cumulative enforcement on the usage the adapter returned
          # synchronously. Missing/unparseable usage halts — fail-closed.
          def record_usage!(input_tokens, output_tokens)
            unless input_tokens.is_a?(Integer) && output_tokens.is_a?(Integer)
              raise CeilingHalt.new(
                :missing_usage,
                "usage data missing from provider response (input=#{input_tokens.inspect}, " \
                "output=#{output_tokens.inspect}) — unmeasurable spend halts (NB-5)"
              )
            end

            @spent_input_tokens += input_tokens
            @spent_output_tokens += output_tokens
            return if remaining_tokens >= 0

            raise CeilingHalt.new(
              :spend,
              "spend ceiling reached: #{@spent_input_tokens + @spent_output_tokens} tokens > #{@max_spend_tokens}"
            )
          end

          def report
            {
              'input_tokens' => @spent_input_tokens,
              'output_tokens' => @spent_output_tokens,
              'total_tokens' => @spent_input_tokens + @spent_output_tokens,
              'steps' => @steps_taken
            }
          end
        end
      end
    end
  end
end
