require 'json'
require 'time'

module KairosMcp
  module KairosChain
    # On-chain record of a single formalization decision.
    # Records why a piece of natural language content was (or was not)
    # converted to a formal AST node.
    class FormalizationDecision
      attr_reader :skill_id, :skill_version, :source_text, :source_span,
                  :result, :rationale, :formalization_category,
                  :ambiguity_before, :ambiguity_after,
                  :decided_by, :model, :timestamp, :confidence,
                  :decompile_text, :source_decompile_divergence

      def initialize(skill_id:, skill_version:, source_text:, result:,
                     rationale:, formalization_category:,
                     source_span: nil, ambiguity_before: nil,
                     ambiguity_after: nil, decided_by: :human,
                     model: nil, timestamp: Time.now.iso8601,
                     confidence: nil, decompile_text: nil,
                     source_decompile_divergence: nil)
        @skill_id = skill_id
        @skill_version = skill_version
        @source_text = source_text
        @source_span = source_span
        @result = result
        @rationale = rationale
        @formalization_category = formalization_category
        @ambiguity_before = ambiguity_before
        @ambiguity_after = ambiguity_after
        @decided_by = decided_by
        @model = model
        @timestamp = timestamp
        @confidence = confidence
        @decompile_text = decompile_text
        @source_decompile_divergence = source_decompile_divergence
      end

      def to_h
        {
          type: :formalization_decision,
          skill_id: @skill_id,
          skill_version: @skill_version,
          source_text: @source_text,
          source_span: @source_span,
          result: @result,
          rationale: @rationale,
          formalization_category: @formalization_category,
          ambiguity_before: @ambiguity_before,
          ambiguity_after: @ambiguity_after,
          decided_by: @decided_by,
          model: @model,
          timestamp: @timestamp,
          confidence: @confidence,
          decompile_text: @decompile_text,
          source_decompile_divergence: @source_decompile_divergence
        }
      end

      def to_json(*args)
        to_h.to_json(*args)
      end

      def self.from_json(json_str)
        data = JSON.parse(json_str, symbolize_names: true)
        data.delete(:type) # Remove the type marker
        new(**data)
      end
    end
  end
end
