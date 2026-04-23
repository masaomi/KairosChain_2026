# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Combine N orchestrator persona reviews into a single reviewer entry
      # that downstream Consensus can treat identically to any other reviewer.
      #
      # Design v0.2 §5: REJECT > REVISE > APPROVE precedence; concatenate
      # reasoning into raw_text so Consensus.aggregate_findings can re-extract
      # P0/P1/... lines uniformly.
      module PersonaAssembly
        MIN_PERSONAS = 2
        MAX_PERSONAS = 4

        module_function

        # @param orchestrator_reviews [Array<Hash>] each: {persona, verdict, findings, reasoning}
        # @param orchestrator_model [String]
        # @return [Hash] reviewer entry with :status, :verdict, :raw_text, :role_label, :provider, :model
        def assemble(orchestrator_reviews, orchestrator_model)
          validate!(orchestrator_reviews)

          verdicts = orchestrator_reviews.map { |r| normalize_verdict(r['verdict'] || r[:verdict]) }
          combined = if verdicts.include?('REJECT')
                       'REJECT'
                     elsif verdicts.include?('REVISE')
                       'REVISE'
                     else
                       'APPROVE'
                     end

          raw_text = build_raw_text(orchestrator_reviews, combined)

          {
            role_label: "claude_team_#{orchestrator_model}",
            provider: 'claude_code',
            model: orchestrator_model,
            raw_text: raw_text,
            elapsed_seconds: 0,
            error: nil,
            status: :success
          }
        end

        def validate!(reviews)
          unless reviews.is_a?(Array)
            raise ArgumentError, 'orchestrator_reviews must be an array'
          end
          if reviews.size < MIN_PERSONAS
            raise ArgumentError, "need at least #{MIN_PERSONAS} persona reviews (got #{reviews.size})"
          end
          if reviews.size > MAX_PERSONAS
            raise ArgumentError, "no more than #{MAX_PERSONAS} persona reviews (got #{reviews.size})"
          end
          reviews.each_with_index do |r, i|
            unless r.is_a?(Hash)
              raise ArgumentError, "review #{i} must be a Hash"
            end
            persona = r['persona'] || r[:persona]
            verdict = r['verdict'] || r[:verdict]
            if persona.nil? || persona.to_s.empty?
              raise ArgumentError, "review #{i} missing required field: persona"
            end
            if verdict.nil? || verdict.to_s.empty?
              raise ArgumentError, "review #{i} missing required field: verdict"
            end
          end
        end

        def normalize_verdict(raw)
          upper = raw.to_s.upcase
          return 'APPROVE' if upper.match?(/\b(?:APPROVE|PASS|ACCEPT)\b/)
          return 'REJECT'  if upper.match?(/\b(?:REJECT|FAIL|BLOCK)\b/)
          'REVISE'
        end

        def build_raw_text(reviews, combined_verdict)
          parts = ["**Overall Verdict**: #{combined_verdict}", '']
          reviews.each do |r|
            persona = r['persona'] || r[:persona]
            verdict = r['verdict'] || r[:verdict]
            reasoning = r['reasoning'] || r[:reasoning] || ''
            findings = r['findings'] || r[:findings] || []

            parts << "## Persona: #{persona} (verdict: #{verdict})"
            parts << ''
            parts << reasoning.to_s unless reasoning.to_s.empty?
            parts << ''
            findings.each do |f|
              if f.is_a?(Hash)
                sev = f['severity'] || f[:severity] || 'P2'
                issue = f['issue'] || f[:issue] || f.to_s
                parts << "**#{sev}**: #{issue}"
              else
                parts << "**P2**: #{f}"
              end
            end
            parts << ''
          end
          parts.join("\n")
        end
      end
    end
  end
end
