# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Agent
      # Bridges agent structures to Autonomos::Mandate API shapes.
      # Input: string keys (from JSON.parse). Output: symbol keys (for Mandate API).
      module MandateAdapter
        # Tools whose presence routes the whole plan to the agent_execute
        # subcontractor instead of in-process autoexec.
        #
        # Defined here rather than in agent_step because the risk gate and the
        # ACT router must agree on the route. If they disagree, a plan can be
        # granted the human-mark exemption below and then run under the
        # subcontractor, which formats steps as prose and never reads the mark
        # — the marked step would be delegated rather than halted on.
        FILE_TOOL_NAMES = %w[Edit Write Read Bash file_edit file_write file_read].freeze

        def self.routes_to_subcontractor?(task_json)
          steps = task_json && task_json['steps']
          Array(steps).any? { |s| FILE_TOOL_NAMES.include?(s['tool_name']) }
        end

        # Convert decision_payload to Mandate-compatible proposal
        # for Mandate.risk_exceeds_budget? and Mandate.loop_detected?
        #
        # enforce_human_marks declares that this caller halts before a marked
        # step at execution time. It lives inside autoexec_task, beside the
        # steps it qualifies, because risk_exceeds_budget? reads that hash and a
        # declaration written elsewhere than it is read is the whole defect.
        def self.to_mandate_proposal(decision_payload)
          task_json = decision_payload['task_json']
          {
            autoexec_task: {
              enforce_human_marks: !routes_to_subcontractor?(task_json),
              steps: Array(task_json && task_json['steps']).map { |s|
                { risk: s['risk'] || 'low',
                  tool_name: s['tool_name'],
                  requires_human_cognition: s['requires_human_cognition'] == true }
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
