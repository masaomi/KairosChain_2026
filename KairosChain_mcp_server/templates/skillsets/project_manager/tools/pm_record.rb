# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ProjectManagerSkillSet
      module Tools
        # Constitutive recording of an irreversible project action (INV-PM-3).
        #
        # The two-trigger boundary (design §4): (i) external-expectation mutation,
        # (ii) disposal of an adopted internal artifact/direction not undoable by
        # ordinary state transition. The judgment that an action crosses this
        # boundary is the operator's (INV-PM-4 human gate) — this tool is invoked
        # only on explicit operator instruction and records what was decided.
        #
        # Reuses the Synoptis attestation chain as the recording substrate (§8:
        # no new ledger). Synoptis is resolved lazily at call time so load order
        # between SkillSets does not matter.
        class PmRecord < KairosMcp::Tools::BaseTool
          include ::ProjectManager::ToolHelpers

          def name
            'pm_record'
          end

          def description
            'Record an irreversible project action constitutively (attestation with provenance): ' \
            'external commitment created/changed/withdrawn, plan adopted/abandoned, project-level ' \
            'scope change, project abandonment, store retirement. Requires explicit operator ' \
            'approval (human gate, INV-PM-4). Routine state changes do NOT go here — use pm_item. ' \
            'Optionally applies a project status change alongside the record.'
          end

          def category
            :project_management
          end

          def usecase_tags
            %w[attestation constitutive_recording irreversible commitment decision]
          end

          def related_tools
            %w[pm_project attestation_list attestation_verify]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                project_id: { type: 'string', description: 'Project this action belongs to' },
                action: { type: 'string',
                          description: 'The irreversible action, e.g. external_commitment_created, ' \
                                       'external_commitment_changed, external_commitment_withdrawn, ' \
                                       'plan_adopted, plan_abandoned, scope_changed, project_abandoned, ' \
                                       'store_retired (open vocabulary — the two-trigger boundary governs, ' \
                                       'not this list)' },
                summary: { type: 'string', description: 'Human-readable statement of what was decided and why' },
                evidence: { type: 'string', description: 'Optional supporting reference (L2 context, document path, message)' },
                item_id: { type: 'string', description: 'Optional related work item; the record is linked to it as provenance' },
                apply_project_status: { type: 'string', enum: %w[active paused done abandoned],
                                        description: 'Optionally set the project status in the same operation' }
              },
              required: %w[project_id action summary]
            }
          end

          def call(arguments)
            project = pm_store.fetch_project(arguments['project_id'])

            attestation = issue_attestation(project, arguments)
            att_ref = attestation[:proof_id] || attestation['proof_id'] ||
                      raise("attestation issued without a proof_id: #{attestation.inspect}")

            entry = { 'kind' => 'attestation', 'ref' => att_ref.to_s,
                      'action' => arguments['action'], 'at' => Time.now.utc.iso8601 }
            pm_store.add_project_provenance(project['id'], entry)
            # Linking the record is bookkeeping about the decision, not new work on
            # the item — mechanical, so it does not advance the item's marker.
            pm_store.add_item_provenance(arguments['item_id'], entry, mechanical: true) if arguments['item_id']

            if arguments['apply_project_status']
              pm_store.update_project(project['id'], { 'status' => arguments['apply_project_status'] })
            end

            text_content(JSON.pretty_generate({
              recorded: true, action: arguments['action'],
              project_id: project['id'], attestation: attestation
            }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          end

          private

          # Constitutive records must not silently expire: the synoptis engine
          # defaults nil ttl to 24h, so we pass an effectively-permanent ttl
          # (config record_ttl_seconds; default 100 years).
          DEFAULT_RECORD_TTL = 100 * 365 * 86_400

          def issue_attestation(project, args)
            ensure_synoptis!
            attestation_engine.create_attestation(
              attester_id: resolve_agent_id,
              subject_ref: "pm://project/#{project['id']}",
              claim: args['action'],
              evidence: JSON.generate({ summary: args['summary'], evidence: args['evidence'],
                                        item_id: args['item_id'] }.compact),
              ttl: (pm_config['record_ttl_seconds'] || DEFAULT_RECORD_TTL).to_i,
              actor_user_id: resolve_actor_user_id,
              actor_role: 'human',
              crypto: resolve_crypto
            )
          end

          # Synoptis loads as its own SkillSet; resolve lazily so this SkillSet
          # does not depend on load order.
          def ensure_synoptis!
            raise 'synoptis SkillSet is not loaded (required for constitutive recording)' unless defined?(::Synoptis::ToolHelpers)

            self.class.include(::Synoptis::ToolHelpers) unless self.class < ::Synoptis::ToolHelpers
          end
        end
      end
    end
  end
end
