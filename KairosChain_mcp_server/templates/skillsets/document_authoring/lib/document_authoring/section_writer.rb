# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module DocumentAuthoring
      # Core write logic: builds LLM prompt, calls llm_call, writes output file.
      class SectionWriter
        def initialize(caller_tool, config)
          @caller = caller_tool
          @config = config
        end

        # Write a document section via LLM.
        # @return [Hash] result with 'status'/'error', 'word_count', etc.
        def write(section_name:, instructions:, context_text:, output_file:,
                  max_words: 500, language: 'en', append_mode: false,
                  invocation_context: nil)
          # Provider-independent completeness: some LLM providers (e.g. the claude_code
          # CLI subprocess) have no output-length control, so a single pass over a long
          # reference context stops early and drops the tail. Split the context at
          # paragraph boundaries and generate each chunk in its own pass, appending the
          # results. Short contexts stay a single pass (chunks == [context_text]).
          chunks = split_context(context_text, chunk_target)
          source_chars = context_text.to_s.gsub(/\s+/, '').length
          complete_at = (source_chars * complete_fraction).ceil

          total_units = 0
          total_chars = 0
          chunks_written = 0
          chunks.each_with_index do |chunk, idx|
            first = idx.zero?
            # Provider-agnostic de-duplication: some output-uncapped providers (e.g. the
            # claude_code CLI) "finish the section" from the first chunk. Once the assembled
            # output already covers ~the whole source, stop — further passes would only
            # append duplicate content. Providers that rewrite each chunk faithfully never
            # trip this (their per-chunk output tracks per-chunk input), so all chunks run.
            break if !first && total_chars >= complete_at

            # Continuation chunks must not repeat the section heading. (A stronger
            # "rewrite only these paragraphs" bound was tried but backfired on the
            # claude_code CLI — it then under-produced and dropped the section tail.)
            chunk_instructions =
              if chunks.length > 1 && !first
                "#{instructions}\n\n#{continuation_note(language)}"
              else
                instructions
              end

            gen = generate_one(section_name, chunk_instructions, chunk, max_words, language, invocation_context)
            return gen if gen['error']

            # First chunk honours the caller's append_mode; later chunks always append
            # so the section is assembled in order.
            write_chunk(output_file, gen['content'], first ? append_mode : true)
            total_units += count_units(gen['content'], language)
            total_chars += gen['content'].gsub(/\s+/, '').length
            chunks_written += 1
          end

          {
            'status' => 'ok',
            'section_name' => section_name,
            'output_file' => output_file,
            # `word_count` (whitespace split) is meaningless for space-less scripts (JA/ZH/KO)
            # and misled progress judgement. Report a language-aware unit count plus a raw
            # non-whitespace char count so callers never size output from a bogus metric.
            'word_count' => total_units,
            'char_count' => total_chars,
            'chunks' => chunks_written
          }
        end

        private

        def system_prompt
          "You are a professional document writer. Write the requested section " \
            "following the instructions precisely. Use the provided context for accuracy. " \
            "Output ONLY the section content. You may use markdown formatting within the section. " \
            "When the instructions ask you to revise, translate, or rewrite the reference " \
            "context, reproduce EVERY paragraph of that context — never summarise, merge, " \
            "shorten, or omit a paragraph, and do not truncate. Preserve heading, list, and " \
            "block-quote structure exactly."
        end

        def build_user_prompt(section_name, instructions, context_text, max_words, language)
          parts = [
            "## Section: #{section_name}",
            "## Instructions\n#{instructions}",
            # `max_words` is a soft target only; the hard cap is enforced via max_tokens.
            # Fidelity to the reference context takes precedence over any word target.
            "## Length: aim for about #{max_words} words, but completeness wins — " \
              "reproduce all reference paragraphs even if that exceeds the target.",
            "## Language: #{language}"
          ]
          parts << "## Reference Context\n#{context_text}" if context_text && !context_text.empty?
          parts << "\nWrite the section now."
          parts.join("\n\n")
        end

        # Derive a hard output token budget so faithful, full-length rewrites are not
        # truncated. Sized from the reference context (rewrite output ≈ input length),
        # clamped between a floor and a ceiling; the adapter clamps further to the
        # model's own limit. Overridable via config for non-default models.
        def resolve_max_tokens(max_words, context_text)
          floor   = (@config['section_max_tokens_floor'] || 4096).to_i
          ceiling = (@config['section_max_tokens_ceiling'] || 8192).to_i
          # ~1 token/char is a safe-high estimate for CJK; +20% margin for markup/expansion.
          est_context = context_text ? (context_text.length * 1.2).ceil : 0
          est_words   = max_words.to_i * 3 # generous; CJK "words" undercount severely
          [[est_context, est_words, floor].max, ceiling].min
        end

        # Language-aware unit count. Space-less scripts count non-whitespace characters;
        # others fall back to whitespace-delimited words.
        def count_units(text, language)
          if %w[ja zh ko].include?(language.to_s)
            text.gsub(/\s+/, '').length
          else
            text.split.size
          end
        end

        # Single LLM pass over one chunk. Returns { 'content' => text } or { 'error' => msg }.
        def generate_one(section_name, instructions, context_text, max_words, language, invocation_context)
          messages = [{
            'role' => 'user',
            'content' => build_user_prompt(section_name, instructions, context_text, max_words, language)
          }]
          llm_args = {
            'messages' => messages,
            'system' => system_prompt,
            'max_tokens' => resolve_max_tokens(max_words, context_text)
          }
          # Forward InvocationContext via dispatch-level context: keyword only.
          result = @caller.invoke_tool('llm_call', llm_args, context: invocation_context)

          raw = result.map { |b| b[:text] || b['text'] }.compact.join
          parsed = JSON.parse(raw)
          if parsed['status'] == 'error'
            error = parsed['error'] || {}
            error_msg = error.is_a?(Hash) ? "#{error['type']}: #{error['message']}" : error.to_s
            return { 'error' => "LLM call failed: #{error_msg}" }
          end

          generated_text = parsed.dig('response', 'content')
          if generated_text.nil? || generated_text.strip.empty?
            return { 'error' => 'LLM returned empty content' }
          end
          { 'content' => generated_text }
        rescue JSON::ParserError => e
          { 'error' => "Failed to parse LLM response: #{e.message}" }
        end

        # Group the reference context into chunks no larger than `target` characters,
        # splitting ONLY at blank-line paragraph boundaries (never mid-paragraph). A short
        # or empty context returns a single element so behaviour is unchanged. A single
        # paragraph larger than `target` stays whole (correctness over chunk size).
        def split_context(text, target)
          return [text] if text.nil? || text.strip.empty? || text.length <= target

          chunks = []
          current = +''
          text.split(/\n{2,}/).each do |para|
            if !current.empty? && (current.length + para.length + 2) > target
              chunks << current
              current = +''
            end
            current << "\n\n" unless current.empty?
            current << para
          end
          chunks << current unless current.empty?
          chunks
        end

        # Auto-chunk threshold. Sized so each pass is small enough that output-uncapped
        # providers (e.g. claude_code CLI) emit a full section without stopping early —
        # empirically a larger single pass truncates, while ~3000-char passes complete.
        # On such providers the first chunk may "finish the section", so the output can
        # carry a trailing duplicate fragment; completeness is favoured over that cosmetic
        # cost. API providers (with max_tokens honoured) produce a clean single section.
        # Overridable via config.
        def chunk_target
          (@config['section_chunk_target_chars'] || 3000).to_i
        end

        # Fraction of the source (by non-whitespace chars) at which the assembled output is
        # considered to already cover the whole section, so remaining chunks are skipped.
        def complete_fraction
          (@config['section_complete_fraction'] || 0.85).to_f
        end

        # Appended to a continuation chunk's instructions so the model does not repeat the
        # section heading and continues the body under the same directives.
        def continuation_note(language)
          if %w[ja zh ko].include?(language.to_s)
            'これは直前のチャンクの続きである。見出し（## …）を繰り返さず、' \
              '本文の続きの段落だけを、同じ方針で自然化して書け。'
          else
            'This is a continuation of the previous chunk. Do NOT repeat the section ' \
              'heading; continue with the next body paragraphs under the same instructions.'
          end
        end

        def write_chunk(output_file, text, append)
          if append
            File.open(output_file, 'a') { |f| f.write("\n\n#{text}") }
          else
            File.write(output_file, text)
          end
        end
      end
    end
  end
end
