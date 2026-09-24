# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Observed model of a persona seat (model_provenance design v0.3, INV-7).
      #
      # A caller may bind each persona to the subagent that ran it, by agent id.
      # The binding is the caller's declaration and is recorded as such; the
      # observation it resolves to was written by the harness-side observer,
      # read here through model_provenance's observation store. This module
      # never reads a Claude Code transcript (INV-2) and never refuses a
      # submission: anything that goes wrong becomes an unobserved persona with
      # the cause this layer saw.
      module ProvenanceBinding
        IDENT = /\A[A-Za-z0-9_.\-]{1,128}\z/
        # What a persona row carries from its observation — enough to read the
        # verdict against, not the whole record.
        ROW_KEYS = %w[persona_state agent_id models anomalies complete run record cause
                      detected_by divergent_models unreadable_records].freeze

        module_function

        # nil when no persona is bound: the seat is then recorded exactly as
        # before this module existed. Otherwise one observation per review, in
        # submission order.
        def resolve(reviews, data_dir: default_data_dir, reader: default_reader)
          return nil unless reviews.is_a?(Array) && reviews.any? { |r| bound?(r) }

          reviews.map { |r| resolve_one(r, data_dir, reader) }
        end

        def bound?(review)
          review.is_a?(Hash) && !(review['agent_id'] || review[:agent_id]).nil?
        end

        def resolve_one(review, data_dir, reader)
          id = review.is_a?(Hash) ? (review['agent_id'] || review[:agent_id]) : nil
          return unobserved('no binding supplied for this persona') if id.nil?
          return unobserved('binding malformed') unless id.is_a?(String) && IDENT.match?(id)
          return unobserved('observation reader not loaded at collect') unless reader

          obs = reader.resolve_binding(data_dir, id)
          return unobserved('observation reader returned no result') unless obs.is_a?(Hash)

          obs.merge('agent_id' => id)
        rescue StandardError => e
          unobserved("binding resolution failed at collect (#{e.class})")
        end

        # One persona against the model it was declared to run on. Evidence
        # read outranks evidence missing: a divergence seen in a partial read
        # stays a divergence, while a partial read that saw none is not an
        # observation of "matching".
        def persona_state(obs, declared)
          return obs.merge('persona_state' => 'unobserved') unless obs['state'] == 'observed'

          models = obs['models'].is_a?(Hash) ? obs['models'] : {}
          others = models.keys.reject { |m| m == declared }.sort
          return obs.merge('persona_state' => 'divergent', 'divergent_models' => others) unless others.empty?
          return obs.merge('persona_state' => 'unobserved', 'cause' => 'observation has no responses') if models.empty?
          unless obs['complete'] == true
            return obs.merge('persona_state' => 'unobserved', 'cause' => 'observation incomplete, no divergence seen')
          end

          obs.merge('persona_state' => 'matching')
        end

        # The seat takes the most severe persona state: divergent > unobserved
        # > matching. It is observed only when every submitted persona is.
        def seat_state(states)
          kinds = states.map { |s| s['persona_state'] }
          all_observed = kinds.none?('unobserved')
          # INV-7: the seat is observed only when every persona's observation is
          # complete; a divergence seen in a partial read still marks it.
          all_complete = all_observed && states.all? { |s| s['complete'] == true }
          models = states.flat_map { |s| s['models'].is_a?(Hash) ? s['models'].keys : [] }.uniq.sort
          divergence = if kinds.include?('divergent') then true
                       elsif all_observed then false
                       end
          { model_source: all_complete ? 'observed' : 'declared',
            model_observed: models.empty? ? nil : models.join(','),
            model_divergence: divergence }
        end

        def row_view(state)
          state.slice(*ROW_KEYS)
        end

        def unobserved(cause)
          { 'state' => 'unobserved', 'cause' => cause, 'detected_by' => 'kairoschain:multi_llm_review_collect' }
        end

        def default_data_dir
          if defined?(KairosMcp) && KairosMcp.respond_to?(:data_dir)
            KairosMcp.data_dir
          else
            File.join(Dir.pwd, '.kairos')
          end
        end

        def default_reader
          return nil unless defined?(KairosMcp::SkillSets::ModelProvenance::ObservationStore)

          KairosMcp::SkillSets::ModelProvenance::ObservationStore
        end
      end
    end
  end
end
