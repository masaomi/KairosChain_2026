# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Agent
      # Bridges agent structures to Autonomos::Mandate API shapes.
      # Input: string keys (from JSON.parse). Output: symbol keys (for Mandate API).
      module MandateAdapter
        # The file route's tools (the agent_execute subcontractor). That route
        # formats steps as prose and never reads a mark, so it is closed until
        # it is wired confined (design v0.3 INV-A1): the act-route table may
        # never classify these names, and every plan runs in-process, where a
        # marked step is deferred.
        FILE_TOOL_NAMES = %w[Edit Write Read Bash file_edit file_write file_read].freeze

        # Convert decision_payload to Mandate-compatible proposal
        # for Mandate.risk_exceeds_budget? and Mandate.loop_detected?
        #
        # enforce_human_marks declares that this caller defers a marked step at
        # execution time. It lives inside autoexec_task, beside the steps it
        # qualifies, because risk_exceeds_budget? reads that hash and a
        # declaration written elsewhere than it is read is the whole defect.
        # With one route, in-process, it always holds.
        #
        # resolved_risk: true when the caller has already resolved each step's
        # risk against the act-route table (ActClassification.apply). The gate
        # then takes that value as given instead of letting its own tool map
        # lower a step the plan labelled higher.
        def self.to_mandate_proposal(decision_payload, resolved_risk: false)
          task_json = decision_payload['task_json']
          {
            autoexec_task: {
              enforce_human_marks: true,
              steps: Array(task_json && task_json['steps']).map { |s|
                step = { risk: s['risk'] || 'low',
                         tool_name: s['tool_name'],
                         requires_human_cognition: s['requires_human_cognition'] == true }
                step[:resolved_risk] = step[:risk] if resolved_risk
                step
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
