# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module Agent
      # Pure logic of the judge distillation (INV-K1, INV-K2): which recorded
      # answers count, what the distiller is shown, what a returned draft must
      # satisfy, and how adopted precedents are rendered. No prompt text and no
      # LLM call lives here.
      module Distiller
        POINTS = %w[plan_proposed cycle_checkpoint].freeze
        THRESHOLD = 10
        HUMAN_TO_JUDGE = {
          'approve' => 'approve',
          'revise' => 'revise',
          'stop' => 'escalate',
          'skip' => 'escalate'
        }.freeze
        OBSERVED_SIGNALS = %w[many_steps l0_change core_files multi_file state_mutation].freeze
        ANSWERS = %w[approve revise escalate].freeze

        MAX_STATEMENTS = 40
        MAX_REASONS = 5
        TEXT_MAX = 400
        DIFF_LINE_LIMIT = 2000
        CONTROL_RE = /[[:cntrl:]\p{Cf}\p{Zl}\p{Zp}]/
        FENCE_RE = /\A```(?:json)?[ \t]*\r?\n(.*?)\r?\n?```\z/m
        FRONT_DESCRIPTION = "The operator's earlier answers at the agent's approval points, " \
                            "generalized by the distiller and adopted by the operator's terminal " \
                            "ruling. Read by the shadow judge."

        module_function

        # One answer per [session_id, anchor]: the highest block wins. The dedup
        # runs BEFORE the filters, so a later unattested answer drops the pair
        # instead of falling back to an older attested one.
        def latest_attested(records)
          latest = {}
          Array(records).each do |rec|
            next unless rec.is_a?(Hash) && rec['kind'] == 'agent_answer'

            key = [rec['session_id'], rec['anchor']]
            held = latest[key]
            latest[key] = rec if held.nil? || block_of(rec) >= block_of(held)
          end
          latest.values.select { |rec| attested_point?(rec) }.sort_by { |rec| block_of(rec) }
        end

        # How many selected answers carry a rationale and sit above the mark.
        def count_new(records, high_water:)
          mark = high_water.nil? ? -1 : high_water.to_i
          latest_attested(records).count do |rec|
            sha = rec['rationale_sha256']
            sha.is_a?(String) && !sha.empty? && block_of(rec) > mark
          end
        end

        # D1: exactly these eight keys. session_id, anchor and the digests are
        # handed to the callables but never emitted.
        def inputs(records, facts:, reason:)
          latest_attested(records).map do |rec|
            {
              'block' => block_of(rec),
              'point' => rec['stop'],
              'decision' => HUMAN_TO_JUDGE[rec['decision']],
              'signals' => (Array(rec['signals']) & OBSERVED_SIGNALS).sort,
              'set_aside' => rec['set_aside'].to_i,
              'cycle' => rec['cycle'],
              'reason' => resolve(reason, rec['session_id'], rec['anchor'], rec['rationale_sha256']),
              'plans' => resolve(facts, rec['session_id'], rec['anchor'], rec['facts_sha256'])
            }
          end
        end

        # => [statements, nil] | [nil, error_string]
        def parse_draft(content, answers)
          text = unfence(content.to_s.strip)
          data = begin
            JSON.parse(text)
          rescue JSON::ParserError
            nil
          end
          return [nil, 'not one JSON object'] unless data.is_a?(Hash)

          raw = data['statements']
          unless raw.is_a?(Array) && !raw.empty? && raw.size <= MAX_STATEMENTS
            return [nil, 'not one JSON object']
          end

          by_block = Array(answers).select { |a| a.is_a?(Hash) }
                                   .each_with_object({}) { |a, h| h[a['block']] = a }
          out = []
          raw.each_with_index do |stmt, idx|
            normalized, error = normalize_statement(stmt, by_block)
            return [nil, "statement #{idx + 1}: #{error}"] if normalized.nil?

            out << normalized
          end
          [out, nil]
        end

        # Renders the adopted precedents. D3: every number below is computed from
        # the sources and the answers, never taken from the draft.
        def render(statements, answers, meta)
          by_block = Array(answers).select { |a| a.is_a?(Hash) }
                                   .each_with_object({}) { |a, h| h[a['block']] = a }
          blocks = by_block.keys.compact.sort
          version = meta.is_a?(Hash) ? meta['version'] : nil

          parts = [
            [
              '---',
              'title: "Agent judgment precedents"',
              %(description: "#{FRONT_DESCRIPTION}"),
              %(version: "#{version}"),
              %(generated_from: "blocks #{blocks.first || 0}..#{blocks.last || 0}"),
              "answers: #{Array(answers).size}",
              '---'
            ].join("\n"),
            '# Agent judgment precedents'
          ]

          Array(statements).each_with_index do |stmt, idx|
            sources = Array(stmt['sources']).sort
            n = sources.size
            agreeing = sources.count { |b| by_block[b] && by_block[b]['decision'] == stmt['answer'] }
            without = sources.count { |b| by_block[b].nil? || by_block[b]['plans'].nil? }
            list = sources.map { |b| "##{b}" }.join(', ')

            parts << "## Situation #{idx + 1}"
            # Model text is labelled, so it cannot stand in for a heading or a
            # count line; every count below is the code's.
            parts << "Situation (as the distiller worded it): #{stmt['situation']}"
            # n is the answers the distiller chose to cite; the line after this
            # one is every answer at the point, which a statement may not cover.
            parts << "Operator answered **#{stmt['answer']}** in #{agreeing} of the #{n} answers this statement " \
                     "cites (blocks #{list}).\nWithout recorded step facts: #{without} of #{n}."
            parts << point_totals(sources.map { |b| by_block[b] && by_block[b]['point'] }.compact.first, answers)

            exceptions = stmt['exceptions'].to_s
            parts << "Exceptions (as the distiller worded them): #{exceptions}" unless exceptions.empty?

            reasons = Array(stmt['reasons'])
            unless reasons.empty?
              parts << (['Reasons given:'] + reasons.map { |text| %(- "#{text}") }).join("\n")
            end
          end

          "#{parts.join("\n\n")}\n"
        end

        # Every answer at the point, computed from all answers rather than the
        # statement's sources (INV-K2: the denominator includes the answers
        # that went the other way, which a statement may leave out).
        def point_totals(point, answers)
          at = Array(answers).select { |a| a.is_a?(Hash) && a['point'] == point }
          by = ANSWERS.map { |d| "#{d} #{at.count { |a| a['decision'] == d }}" }.join(', ')
          without = at.count { |a| a['plans'].nil? }
          "All #{at.size} answers at #{point}: #{by}; without recorded step facts: #{without}."
        end

        def line_diff(old_text, new_text)
          old_lines = old_text.to_s.lines.map(&:chomp)
          new_lines = new_text.to_s.lines.map(&:chomp)
          return '' if old_lines == new_lines

          # The LCS table is O(n*m): past the guard, report every line of each side.
          if old_lines.size > DIFF_LINE_LIMIT || new_lines.size > DIFF_LINE_LIMIT
            return (old_lines.map { |l| "- #{l}" } + new_lines.map { |l| "+ #{l}" }).join("\n")
          end

          table = lcs_table(old_lines, new_lines)
          out = []
          i = 0
          j = 0
          while i < old_lines.size || j < new_lines.size
            if i < old_lines.size && j < new_lines.size && old_lines[i] == new_lines[j]
              i += 1
              j += 1
            elsif i < old_lines.size && (j >= new_lines.size || table[i + 1][j] >= table[i][j + 1])
              # Removals come before additions at a divergence.
              out << "- #{old_lines[i]}"
              i += 1
            else
              out << "+ #{new_lines[j]}"
              j += 1
            end
          end
          out.join("\n")
        end

        # D3: model text is made single-line, collapsed, then cut to max.
        def single_line(text, max)
          limit = max.to_i
          return '' if limit <= 0

          text.to_s.gsub(CONTROL_RE, ' ').squeeze(' ').strip.slice(0, limit).to_s
        end

        # --- internals (public only because of module_function) ----------------

        def block_of(rec)
          rec['block'].to_i
        end

        def attested_point?(rec)
          rec['attestation'] == 'terminal_nonce' &&
            POINTS.include?(rec['stop']) &&
            HUMAN_TO_JUDGE.key?(rec['decision'])
        end

        # A callable is invoked only when its digest is present; one that raises gives nil.
        def resolve(callable, session_id, anchor, sha)
          return nil unless callable.respond_to?(:call)
          return nil unless sha.is_a?(String) && !sha.empty?

          callable.call(session_id, anchor, sha)
        rescue StandardError
          nil
        end

        # Unwrap only when the whole text is exactly one fenced block.
        def unfence(text)
          match = FENCE_RE.match(text)
          return text if match.nil?

          inner = match[1].to_s
          inner.include?('```') ? text : inner.strip
        end

        # => [statement, nil] | [nil, "<what>"]; the caller prefixes the index.
        def normalize_statement(stmt, by_block)
          return [nil, 'not an object'] unless stmt.is_a?(Hash)

          situation = stmt['situation']
          return [nil, 'situation is not a string'] unless situation.is_a?(String)

          situation = single_line(situation, TEXT_MAX)
          return [nil, 'situation is empty'] if situation.empty?

          answer = stmt['answer']
          return [nil, "answer is not one of #{ANSWERS.join('/')}"] unless ANSWERS.include?(answer)

          sources = stmt['sources']
          unless sources.is_a?(Array) && !sources.empty? && sources.all?(Integer)
            return [nil, 'sources is not a non-empty array of integers']
          end
          return [nil, 'sources are not unique'] unless sources.uniq.size == sources.size

          unknown = sources.reject { |b| by_block.key?(b) }
          return [nil, "sources name no answer: #{unknown.join(', ')}"] unless unknown.empty?

          # INV-K2 counts n of m at one kind of point.
          points = sources.map { |b| by_block[b]['point'] }.uniq
          return [nil, "sources span more than one point: #{points.join(', ')}"] if points.size > 1

          count = stmt['count']
          return [nil, 'count is not an integer'] unless count.is_a?(Integer)

          # D2: the count is recomputed from the sources; a differing count is refused.
          recomputed = sources.count { |b| by_block[b]['decision'] == answer }
          unless count == recomputed
            return [nil, "count #{count} is not the #{recomputed} recomputed from sources"]
          end

          exceptions = stmt['exceptions']
          unless exceptions.nil? || exceptions.is_a?(String)
            return [nil, 'exceptions is not a string']
          end

          reasons = stmt['reasons']
          return [nil, 'reasons is not an array'] unless reasons.nil? || reasons.is_a?(Array)

          reasons = reasons.nil? ? [] : reasons
          return [nil, "reasons has more than #{MAX_REASONS} entries"] if reasons.size > MAX_REASONS

          recorded = sources.map { |b| by_block[b]['reason'] }.compact
          reasons.each do |text|
            return [nil, 'a reason is not a string'] unless text.is_a?(String)
            # D2: a quoted reason must equal exactly the reason of one of its sources.
            return [nil, 'a reason is not the reason of any source'] unless recorded.include?(text)
          end

          [{
            'situation' => situation,
            'answer' => answer,
            'sources' => sources.sort,
            'count' => count,
            'exceptions' => exceptions.nil? ? '' : single_line(exceptions, TEXT_MAX),
            'reasons' => reasons.map { |text| single_line(text, TEXT_MAX) }
          }, nil]
        end

        # Suffix-form LCS lengths: table[i][j] covers old[i..] against new[j..].
        def lcs_table(old_lines, new_lines)
          table = Array.new(old_lines.size + 1) { Array.new(new_lines.size + 1, 0) }
          (old_lines.size - 1).downto(0) do |i|
            (new_lines.size - 1).downto(0) do |j|
              table[i][j] = if old_lines[i] == new_lines[j]
                              table[i + 1][j + 1] + 1
                            else
                              [table[i + 1][j], table[i][j + 1]].max
                            end
            end
          end
          table
        end
      end
    end
  end
end
