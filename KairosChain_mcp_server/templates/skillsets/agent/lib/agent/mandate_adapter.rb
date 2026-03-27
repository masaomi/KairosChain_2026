# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Agent
      # Bridges agent structures to Autonomos::Mandate API shapes.
      # Input: string keys (from JSON.parse). Output: symbol keys (for Mandate API).
      module MandateAdapter
        # Convert decision_payload to Mandate-compatible proposal
        # for Mandate.risk_exceeds_budget? and Mandate.loop_detected?
        def self.to_mandate_proposal(decision_payload)
          {
            autoexec_task: {
              steps: (decision_payload['task_json']['steps'] || []).map { |s|
                { risk: s['risk'] || 'low', tool_name: s['tool_name'] }
              }
            },
            selected_gap: {
              description: decision_payload['summary']
            }
          }
        end

        # Extract gap description from ORIENT output for loop_detected?
        def self.extract_gap_description(orient_result)
          gaps = orient_result['gaps'] || []
          gaps.first || orient_result['recommended_action'] || 'unknown'
        end

        # Map REFLECT confidence to Mandate evaluation string.
        # 'partial' is not in VALID_STATUSES but is accepted by record_cycle
        # (only 'failed'/'unknown' increment consecutive_errors).
        def self.reflect_to_evaluation(reflect_result)
          confidence = reflect_result['confidence'].to_f
          case
          when confidence >= 0.7 then 'success'
          when confidence >= 0.3 then 'partial'
          when confidence > 0.0  then 'failed'
          else 'unknown'
          end
        end
      end
    end
  end
end
