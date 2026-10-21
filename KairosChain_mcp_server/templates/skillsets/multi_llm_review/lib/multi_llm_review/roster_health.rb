# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # INV-H2 (design log/mlr_non_claude_host_design_v0.3.3): the state of the
      # roster, stated wherever a result is read, from what was observed.
      #
      # Derived from denominator_composition alone, so the synchronous path and
      # collect read it from one place. A persona and the slot it took over are
      # one seat: the slot's row carries `replaced_by` and is not counted again.
      # `counted` is therefore the same set vote_tally's successful_count
      # counts — rows whose verdict is not SKIP.
      #
      # Each counted seat's maker comes with where it comes from, following the
      # row's own provenance:
      #   observed   — the row's model_source is `observed`
      #   configured — a dispatched slot whose row is declaration-derived: the
      #                model the roster pins and the system dispatched, held on
      #                its provider by no_fallback
      #   declared   — a synthetic row not observed: the caller said so
      # Maker diversity is established only by two counted seats whose makers
      # are observed or configured and differ.
      #
      # Counting `configured` narrows INV-E5 for this one test (ruling 8): INV-E5
      # classes every row whose transport cannot report its model as
      # declaration-derived, and this splits that class by who declared — the
      # system's own pin counts, the caller's word never does. It holds while
      # the CLI's own configuration does not route the pinned name to another
      # maker; that is stated, not checked. Everywhere else the row's
      # model_source stays `declared`.
      module RosterHealth
        # A closed table. A model it does not name is `unknown`, which never
        # establishes diversity, so a gap here errs toward showing the mark.
        MAKER_PREFIXES = [
          [/\Aclaude-/, 'anthropic'],
          [/\Agpt-/, 'openai'],
          [/\Ao\d/, 'openai'],
          [/\Acodex-/, 'openai'],
          [/\Acomposer-/, 'cursor'],
          [/\Agemini-/, 'google']
        ].freeze
        UNKNOWN = 'unknown'

        SOURCE_OBSERVED = 'observed'
        SOURCE_CONFIGURED = 'configured'
        SOURCE_DECLARED = 'declared'

        module_function

        # A value naming more than one model (a persona seat whose personas were
        # observed on different models is recorded comma-joined) has no single
        # maker.
        def maker_of(model)
          name = model.to_s.strip
          return UNKNOWN if name.empty? || name.include?(',')

          MAKER_PREFIXES.each { |re, maker| return maker if re.match?(name) }
          UNKNOWN
        end

        def source_of(row)
          return SOURCE_OBSERVED if fetch(row, :model_source).to_s == 'observed'
          return SOURCE_DECLARED if fetch(row, :synthetic) == true

          SOURCE_CONFIGURED
        end

        def model_for(row, source)
          observed = fetch(row, :model_observed)
          return observed if source == SOURCE_OBSERVED && observed

          fetch(row, :model)
        end

        # @param observers [Array<Hash>] denominator_composition[:observers]
        def build(observers)
          rows = Array(observers).reject { |o| present?(fetch(o, :replaced_by)) }
          counted = rows.select { |o| fetch(o, :counted) == true }
          not_counted = rows.reject { |o| fetch(o, :counted) == true }

          makers = counted.map do |row|
            source = source_of(row)
            { role_label: fetch(row, :role_label),
              maker: maker_of(model_for(row, source)),
              source: source }
          end
          known = makers.reject { |m| m[:source] == SOURCE_DECLARED || m[:maker] == UNKNOWN }
                        .map { |m| m[:maker] }.uniq

          {
            seats: rows.size,
            counted: counted.size,
            not_counted: not_counted.map { |o|
              { role_label: fetch(o, :role_label), reason: fetch(o, :reason) }.compact
            },
            makers: makers,
            maker_diversity: known.size >= 2 ? 'established' : 'not_established',
            counted_declared: makers.count { |m| m[:source] == SOURCE_DECLARED }
          }
        end

        # The roster line is due when a seat did not count or maker diversity
        # is not established.
        def degraded?(health)
          return false unless health

          !Array(fetch(health, :not_counted)).empty? ||
            fetch(health, :maker_diversity).to_s != 'established'
        end

        def fetch(hash, key)
          return nil unless hash.is_a?(Hash)

          hash.key?(key) ? hash[key] : hash[key.to_s]
        end

        def present?(value)
          !value.nil? && !value.to_s.strip.empty?
        end
      end
    end
  end
end
