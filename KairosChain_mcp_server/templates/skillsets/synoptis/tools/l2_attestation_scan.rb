# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        # ACT-5 (liveness) + ACT-2 (criterion): fire the selection criterion at a trigger
        # point, surface judgment-bearing L2 contexts as PROPOSALS (no attestation, no
        # obligation), and append one trigger record to the operational log so that
        # "fired and surfaced N" is distinguishable from "never ran".
        #
        # Propose-only: this tool writes only telemetry (a trigger record). Nothing is
        # attested here — approval happens in l2_attestation_commit (ACT-1).
        class L2AttestationScan < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'l2_attestation_scan'
          end

          def description
            'Propose judgment-bearing L2 contexts (handoff/decision/debrief) from a session for constitutive attestation. Surfaces proposals only; approve each via l2_attestation_commit. Logs a trigger record (ACT-5).'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[attestation propose constitutive l2 audit]
          end

          def related_tools
            %w[l2_attestation_commit l2_attestation_decline]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                session_id: { type: 'string', description: 'Session to scan (default: most recently modified session).' }
              }
            }
          end

          def call(arguments)
            session_id = arguments['session_id'] || latest_session_id
            unless session_id
              return text_content(JSON.pretty_generate({ status: 'error', message: 'No session found to scan.' }))
            end

            proposals = proposal_criterion.propose(session_id: session_id)
            constitutive_chain.append_trigger(surfaced_count: proposals.length)

            text_content(JSON.pretty_generate({
              status: 'proposed',
              session_id: session_id,
              surfaced_count: proposals.length,
              rubric: constitutive_rubric,
              proposals: proposals,
              note: 'ACT-2 semantic layer: apply the rubric to each proposal\'s preview, then propose the ones that qualify to the human. Approve via l2_attestation_commit(subject:, approved: true) (optionally embed_snapshot: true), or record a decline via l2_attestation_decline(subject:).'
            }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ status: 'error', message: e.message }))
          end
        end
      end
    end
  end
end
