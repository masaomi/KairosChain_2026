# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative 'entry'

module Synoptis
  module Anchoring
    # Declared anchoring rule (aud_l2_mutual_anchoring_design v0.5 MAP-3)
    # under map-1 §5: a result-free rule artifact whose schema is closed by
    # construction (no field can reference an outcome), committed on the chain
    # for decidable anteriority, and a coverage CHECKER that reports — never
    # enforces. A sparse or vacuous rule conforms; the report makes its cost
    # visible. No automation lives here (cadence automation is out of this
    # slice; the canonical-works human gate is untouched).
    module AnchoringRule
      FORMAT = 'map-1/anchoring-rule'
      COMMITMENT_FORMAT = 'map-1/rule-commitment'
      TRIGGERS = %w[every_n_records every_n_days].freeze
      FIELDS = %w[format n trigger].freeze
      HEX_DIGEST = /\A[a-f0-9]{64}\z/
      # JSON-safe bound, matching HeadBinding (ANC-2 boundedness).
      JSON_SAFE_BOUND = 2**53

      class RuleError < StandardError; end

      module_function

      # Build a rule artifact string (canonical JSON, map-1 §5).
      def build(trigger, n)
        t = trigger.to_s
        raise RuleError, "trigger must be one of #{TRIGGERS.join(', ')}, got #{t.inspect}" unless TRIGGERS.include?(t)
        unless n.is_a?(Integer) && n.positive? && n < JSON_SAFE_BOUND
          raise RuleError, "n must be a positive JSON-safe Integer, got #{n.inspect}"
        end

        Entry.canonical_json('format' => FORMAT, 'n' => n, 'trigger' => t)
      end

      # Parse + validate a rule artifact string. Raises RuleError on the first
      # violation (a rule is an operator-authored artifact: malformed means
      # refused, not coerced).
      def parse!(rule_string)
        parsed = begin
          JSON.parse(rule_string.to_s)
        rescue JSON::ParserError => e
          raise RuleError, "rule is not valid JSON: #{e.message}"
        end
        raise RuleError, "rule must be a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)

        r = parsed.transform_keys(&:to_s)
        keys = r.keys.sort
        raise RuleError, "rule fields must be exactly #{FIELDS.join(', ')}, got #{keys.join(', ')}" unless keys == FIELDS
        raise RuleError, "unknown format #{r['format'].inspect} (#{FORMAT} only)" unless r['format'] == FORMAT
        raise RuleError, "trigger must be one of #{TRIGGERS.join(', ')}" unless TRIGGERS.include?(r['trigger'])
        unless r['n'].is_a?(Integer) && r['n'].positive? && r['n'] < JSON_SAFE_BOUND
          raise RuleError, 'rule.n must be a positive JSON-safe Integer'
        end
        # map-1 §5: a rule is valid only in its canonical serialization, so one
        # rule has exactly one digest — a re-ordered or re-spaced serialization
        # would commit a different digest for the same logical rule.
        unless Entry.canonical_json(r) == rule_string.to_s
          raise RuleError, 'rule is not in canonical serialization (map-1 §5: one rule, one digest)'
        end

        r
      end

      # The rule-commitment record string (map-1 §5) the chain commits so the
      # rule's anteriority is decidable in committed order (MPR-8).
      def commitment_record(rule_string)
        parse!(rule_string)
        Entry.canonical_json(
          'format' => COMMITMENT_FORMAT,
          'rule_digest' => Digest::SHA256.hexdigest(rule_string.to_s)
        )
      end

      # Coverage report (map-1 §5): the rule held against the visible anchor
      # history. Diagnostic posture: never raises on the history side — asked
      # "is this history covered?", the answer is a report, not an exception.
      #
      # +rule_string+   the committed rule artifact.
      # +anchors+       the binding-carrying anchor observations, each a Hash
      #                 with 'tree_size' (Integer) and 'moment' (ISO8601
      #                 String) — the shape a reader extracts from head
      #                 bindings + entry moments.
      # +chain_extent+  current record count of the internal chain.
      # +rule_position+ committed record position of the rule commitment
      #                 (for every_n_records) — expectation starts after it.
      # +rule_moment+   committed moment of the rule commitment (ISO8601, for
      #                 every_n_days).
      # +now+           end of the assessed window (ISO8601); required for
      #                 every_n_days so the checker stays clock-free.
      #
      # Returns { conforms: true, expected: [...], matched: [...], gaps: [...],
      #           note: } — `conforms` is always true for a valid rule (MAP-3:
      #           a vacuous rule conforms); the gaps are the visible cost.
      def coverage(rule_string, anchors, chain_extent: nil, rule_position: nil, rule_moment: nil, now: nil)
        rule = parse!(rule_string)
        observations = Array(anchors).map { |a| a.is_a?(Hash) ? a.transform_keys(&:to_s) : {} }

        case rule['trigger']
        when 'every_n_records'
          coverage_by_records(rule, observations, chain_extent, rule_position)
        when 'every_n_days'
          coverage_by_days(rule, observations, rule_moment, now)
        end
      end

      # -- internal helpers --

      def coverage_by_records(rule, observations, chain_extent, rule_position)
        extent = begin
          Integer(chain_extent || 0)
        rescue ArgumentError, ::TypeError
          raise RuleError, "chain_extent must be an Integer, got #{chain_extent.inspect}"
        end
        start = begin
          Integer(rule_position || 0)
        rescue ArgumentError, ::TypeError
          raise RuleError, "rule_position must be an Integer, got #{rule_position.inspect}"
        end
        n = rule['n']
        sizes = observations.map { |o| o['tree_size'] }.select { |s| s.is_a?(Integer) }.sort
        expected = []
        threshold = start + n
        while threshold <= extent
          expected << threshold
          threshold += n
        end
        matched = expected.select { |e| sizes.any? { |s| s >= e && s < e + n } }
        gaps = expected - matched
        {
          conforms: true,
          # Echo the assessed frame so a defaulted rule_position is visible in
          # the report, never silently assumed.
          chain_extent: extent,
          rule_position: start,
          expected: expected,
          matched: matched,
          gaps: gaps,
          note: gaps.empty? ? 'covered' : "#{gaps.size} expected anchor point(s) without a binding-carrying anchor; temporal windows widen accordingly (MPR-7)"
        }
      end

      def coverage_by_days(rule, observations, rule_moment, now)
        raise RuleError, 'every_n_days coverage needs rule_moment and now (ISO8601)' if rule_moment.nil? || now.nil?

        t0 = Time.iso8601(rule_moment.to_s)
        t1 = Time.iso8601(now.to_s)
        n_sec = rule['n'] * 86_400
        moments = observations.map { |o| o['moment'] }.filter_map do |m|
          Time.iso8601(m.to_s)
        rescue ArgumentError
          nil
        end
        expected = []
        boundary = t0 + n_sec
        while boundary <= t1
          expected << boundary.utc.iso8601
          boundary += n_sec
        end
        matched = expected.select do |e|
          et = Time.iso8601(e)
          moments.any? { |m| m >= et && m < et + n_sec }
        end
        gaps = expected - matched
        {
          conforms: true,
          rule_moment: t0.utc.iso8601,
          assessed_until: t1.utc.iso8601,
          expected: expected,
          matched: matched,
          gaps: gaps,
          note: gaps.empty? ? 'covered' : "#{gaps.size} expected anchor window(s) without a binding-carrying anchor; temporal windows widen accordingly (MPR-7)"
        }
      rescue ArgumentError => e
        raise RuleError, "invalid ISO8601 input: #{e.message}"
      end
    end
  end
end
