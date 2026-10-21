# frozen_string_literal: true

require_relative 'sanitizer'
require_relative 'roster_health'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Formats aggregated_findings into Agent-consumable feedback_text.
      #
      # Phase 12 §3.7. Pure function of findings — same input always produces
      # identical text (golden-file testable).
      #
      # Order: sanitize → truncate → severity prefix (severity is never cut).
      class FeedbackFormatter
        # 2: a roster line now precedes any findings, and appears on APPROVE too
        # (where the text used to be null) when a seat did not count or maker
        # diversity is not established (INV-H2). INSUFFICIENT states counted and
        # needed seats, each uncounted seat with its reason, and an action only
        # where one would restore that seat.
        SCHEMA_VERSION = 2
        MAX_FINDINGS_PER_FEEDBACK = 50
        MAX_AGGREGATED_FINDINGS = 200

        # Build feedback_text from aggregated findings.
        #
        # @param findings [Array<Hash>] each with :severity / 'severity' and :issue / 'issue'
        # @return [String] deterministic, sanitized feedback text
        def self.build(findings)
          return '' if findings.nil? || findings.empty?

          findings = Array(findings).first(MAX_AGGREGATED_FINDINGS)
          shown = findings.first(MAX_FINDINGS_PER_FEEDBACK)
          omitted = findings.size - shown.size

          lines = ['Multi-LLM review found issues:']
          shown.each do |f|
            severity = stringify(f[:severity] || f['severity'] || 'P?')
            issue    = Sanitizer.sanitize_finding_text(f[:issue] || f['issue'])
            lines << "- #{severity}: #{issue}"
          end
          if omitted.positive?
            lines << "... (#{omitted} more findings omitted; see aggregated_findings array for full list)"
          end
          lines << ''
          lines << 'Revise plan to address these.'
          lines.join("\n")
        end

        # Build feedback_text for INSUFFICIENT verdict (§3.7.4).
        # Error string is also untrusted (may reflect reviewer content) → sanitized.
        def self.build_insufficient(error_msg)
          sanitized = Sanitizer.sanitize_finding_text(error_msg, max_len: 200)
          "Multi-LLM review could not complete (reason: #{sanitized}). Plan needs human review or retry."
        end

        # Actions an operator can take outside the review that would restore a
        # seat lost to this reason. A reason not listed gets none, and nothing
        # is invented for it. No strategy is ever advised here: which strategy
        # suits a host has conditions a one-line action cannot carry (design
        # v0.3.3 §2 INV-H2 Why), so the runbook carries them.
        def self.action_for(reason, context = {})
          case reason.to_s
          when 'cli_missing'
            'install the CLI, or put its directory on the PATH the server searched (shown above)'
          when 'cli_unauthenticated'
            "log in with that CLI's own command (codex login / agent login / claude, then /login); " \
              'the seat reads the login under HOME'
          when 'workspace_refused'
            "make the server's working directory (#{context[:cwd]}) lie inside a git repository; " \
              'how a host sets that directory is the host\'s'
          when 'cli_timeout', 'dispatch_timeout'
            "raise llm_client's timeout_seconds and multi_llm_review's timeout_seconds together " \
              '(both 600 shipped); collect_deadline_seconds bounds how far that helps'
          end
        end

        INSUFFICIENT_MAX_LEN = 4000
        # What a not-counted row with no reason is written as. Not a reason
        # token, and not "unknown" (the maker table's word).
        NO_REASON = 'no reason recorded'

        # Whole lines only, in order, within max_len; when a line does not fit,
        # one closing line says how many were left out and where to read them.
        # The counts and the roster line come first, so they are never the
        # lines that go.
        def self.bounded_lines(lines, max_len)
          clean = lines.map { |l| Sanitizer.sanitize_finding_text(l, max_len: max_len) }
          kept = []
          used = 0
          clean.each_with_index do |line, i|
            rest = clean.size - i
            marker = "… #{rest} more line(s) left out; vote_tally.roster_health has every seat."
            need = used + line.size + (kept.empty? ? 0 : 1)
            if need > max_len || (rest > 1 && need + marker.size + 1 > max_len)
              kept << marker
              break
            end
            kept << line
            used = need
          end
          kept.join("\n")
        end

        # The one line INV-H2 requires. Shaped as a statement about the roster,
        # never as a finding: it carries no severity tag.
        def self.roster_line(health)
          h = health || {}
          get = ->(k) { h[k] || h[k.to_s] }
          lost = Array(get.(:not_counted)).group_by { |r| (r[:reason] || r['reason'] || NO_REASON).to_s }
          lost_text = lost.map { |reason, rows|
            "#{reason}: #{rows.map { |r| r[:role_label] || r['role_label'] }.join(', ')}"
          }.join('; ')
          diversity = get.(:maker_diversity).to_s == 'established' ? 'established' : 'not established'
          line = "Roster: #{get.(:counted)} of #{get.(:seats)} seats counted " \
                 "(#{get.(:counted_declared) || 0} caller-declared)"
          line += " — not counted: #{lost_text}" unless lost_text.empty?
          line + "; maker diversity #{diversity}."
        end

        def self.build_insufficient_for(vote_tally, context = {})
          vt = vote_tally || {}
          get = ->(k) { vt[k] || vt[k.to_s] }
          health = get.(:roster_health) || {}
          counted = get.(:successful_count).to_i
          needed = get.(:min_quorum).to_i
          # The roster line and the counts come first, so that bounding the
          # text can only ever cut the per-seat actions, never the account of
          # which seats did not count (INV-H2). The PATH is shown once, not
          # once per missing seat.
          lines = ["Multi-LLM review could not complete: #{counted} of #{needed} seats needed counted.",
                   roster_line(health)]
          if counted < needed
            lines << 'A seat can be added in config: a slot naming provider, model and role_label, ' \
                     'on a model the roster does not already name.'
          end
          not_counted = Array(health[:not_counted] || health['not_counted'])
          if not_counted.any? { |r| (r[:reason] || r['reason']).to_s == 'cli_missing' }
            lines << "PATH the server searched: #{context[:path]}"
          end
          not_counted.each do |row|
            reason = row[:reason] || row['reason'] || NO_REASON
            action = action_for(reason, context)
            label = row[:role_label] || row['role_label']
            lines << (action ? "- #{label}: #{reason} — #{action}" : "- #{label}: #{reason}")
          end
          bounded_lines(lines, INSUFFICIENT_MAX_LEN)
        end

        # feedback_text for a computed result (INV-H2). nil only when the
        # verdict is APPROVE and the roster is whole.
        def self.for_result(consensus, sanitized_findings, context = {})
          vt = consensus[:vote_tally] || {}
          health = vt[:roster_health] || vt['roster_health']
          case consensus[:reference_verdict]
          when 'INSUFFICIENT'
            build_insufficient_for(vt, context)
          when 'APPROVE'
            RosterHealth.degraded?(health) ? Sanitizer.sanitize_finding_text(roster_line(health), max_len: 1000) : nil
          else
            body = build(sanitized_findings)
            return body unless RosterHealth.degraded?(health)

            line = Sanitizer.sanitize_finding_text(roster_line(health), max_len: 1000)
            body.empty? ? line : "#{line}\n#{body}"
          end
        end

        def self.stringify(s)
          s.to_s.gsub(/[^A-Za-z0-9?]/, '')[0, 8]
        end
        private_class_method :stringify
      end
    end
  end
end
