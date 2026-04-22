# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Three-state consensus engine for multi-LLM review results.
      #
      # States:
      #   APPROVE — reviewer explicitly approved
      #   REJECT  — reviewer explicitly rejected (deliberate)
      #   SKIP    — transport error, timeout, ENOENT, or cancelled
      #
      # Verdicts:
      #   APPROVE      — enough approvals, no rejections
      #   REVISE       — any rejection, or not enough approvals
      #   INSUFFICIENT — fewer than min_quorum successful reviews
      class Consensus
        VERDICT_PATTERNS = {
          approve: /\b(?:APPROVE[D]?|PASS|ACCEPT)\b/i,
          reject:  /\b(?:REJECT(?:ED)?|FAIL(?:ED)?|BLOCK(?:ED)?)\b/i,
          revise:  /\b(?:REVISE|CHANGES?\s*REQUIRED|NEEDS?\s*WORK)\b/i
        }.freeze

        # @param reviews [Array<Hash>] from Dispatcher, each with :status, :raw_text, :role_label, etc.
        # @param rule_str [String] e.g., "3/4 APPROVE"
        # @param min_quorum [Integer] minimum successful reviews needed
        # @return [Hash] with :verdict, :convergence, :reviews, :aggregated_findings
        def self.aggregate(reviews, rule_str = '3/4 APPROVE', min_quorum: 2)
          parsed = reviews.map { |r| extract_verdict(r) }

          successful = parsed.select { |p| p[:verdict] != 'SKIP' }
          skipped    = parsed.select { |p| p[:verdict] == 'SKIP' }
          approve_n  = successful.count { |p| p[:verdict] == 'APPROVE' }
          reject_n   = successful.count { |p| p[:verdict] == 'REJECT' }

          threshold = parse_threshold(rule_str, successful.size)

          overall = if successful.size < min_quorum
                      'INSUFFICIENT'
                    elsif reject_n > 0
                      'REVISE'
                    elsif approve_n >= threshold
                      'APPROVE'
                    else
                      'REVISE'
                    end

          findings = aggregate_findings(parsed)
          {
            verdict: overall,
            convergence: {
              approve_count: approve_n,
              reject_count: reject_n,
              skip_count: skipped.size,
              successful_count: successful.size,
              total_configured: reviews.size,
              threshold: threshold,
              min_quorum: min_quorum,
              rule: rule_str
            },
            reviews: parsed,
            aggregated_findings: findings
          }
        end

        # Extract verdict from a single review result.
        # Transport errors → SKIP (excluded from denominator).
        def self.extract_verdict(review)
          if review[:status] == :skip || review[:status] == :error
            return review.merge(verdict: 'SKIP')
          end

          text = review[:raw_text].to_s

          # Try structured JSON first (e.g., {"overall_verdict": "APPROVE"})
          if text =~ /"overall_verdict"\s*:\s*"([^"]+)"/i
            return review.merge(verdict: normalize_verdict($1))
          end

          # Try **Overall Verdict**: line (structured markdown)
          if text =~ /\*{0,2}Overall\s+Verdict\*{0,2}\s*:\s*(\w+)/i
            return review.merge(verdict: normalize_verdict($1))
          end

          # Regex heuristic: check reject before revise before approve
          return review.merge(verdict: 'REJECT') if text.match?(VERDICT_PATTERNS[:reject])
          return review.merge(verdict: 'REVISE') if text.match?(VERDICT_PATTERNS[:revise])
          return review.merge(verdict: 'APPROVE') if text.match?(VERDICT_PATTERNS[:approve])

          # Unparseable → conservative REVISE
          review.merge(verdict: 'REVISE')
        end

        def self.normalize_verdict(raw)
          upper = raw.to_s.upcase
          return 'APPROVE' if upper.match?(VERDICT_PATTERNS[:approve])
          return 'REJECT'  if upper.match?(VERDICT_PATTERNS[:reject])
          'REVISE'
        end

        # Ratio-based threshold applied to successful count.
        # "3/4 APPROVE" with 2 successful → ceil(2 * 0.75) = 2
        def self.parse_threshold(rule_str, successful_count)
          return 1 if successful_count <= 0

          if rule_str =~ %r{(\d+)\s*/\s*(\d+)}
            ratio = $1.to_f / $2.to_f
            (successful_count * ratio).ceil
          else
            (successful_count * 0.75).ceil
          end
        end

        # Collect severity-tagged findings from all successful reviews.
        # Deduplicates by first 80 chars (case-insensitive).
        def self.aggregate_findings(parsed_verdicts)
          all_findings = []
          parsed_verdicts.each do |r|
            next if r[:verdict] == 'SKIP'
            text = r[:raw_text].to_s

            # Extract "P0: ...", "P1-1: ...", "**P0**:", etc.
            text.scan(/\*{0,2}(P[0-3])\*{0,2}[-\s]*\d*[.:]\s*(.+?)(?=\n\s*\n|\n\s*\*{0,2}P[0-3]|\z)/mi) do |sev, issue|
              all_findings << {
                severity: sev.upcase,
                issue: issue.strip[0..200],
                cited_by: [r[:role_label]]
              }
            end
          end

          # Deduplicate by first 80 chars
          grouped = all_findings.group_by { |f| f[:issue][0..79].downcase }
          grouped.map do |_key, findings|
            {
              severity: findings.map { |f| f[:severity] }.min, # P0 < P1 < P2
              issue: findings.first[:issue],
              cited_by: findings.flat_map { |f| f[:cited_by] }.uniq
            }
          end.sort_by { |f| f[:severity] }
        end
      end
    end
  end
end
