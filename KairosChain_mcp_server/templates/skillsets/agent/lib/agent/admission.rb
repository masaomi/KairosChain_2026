# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Agent
      # Admission — AGT-5 store-write admission for the in-process act route,
      # plus AGT-1 route symmetry for in-process live-tree writers
      # (guard track design v0.3.1 FROZEN).
      #
      # Store-touching writes performed within an agent cycle are admitted
      # against the mandate's declared layer surface, pinned before the loop
      # ran. Enforcement is refusal, not detection: denied tools are added to
      # the ACT invocation-context blacklist, so the call is refused at
      # dispatch (PolicyDeniedError) and the write never lands.
      #
      # - The declaration can name only governance-store surfaces (l0 / l1).
      #   The record store is NEVER declarable: record-store tools are in the
      #   deny set for every possible declaration — refused by construction,
      #   not by favorable interpretation.
      # - The single path to the record store is the driver's own constitutive
      #   recording (record_agent_cycle and the driver's checkpoint records),
      #   which runs in driver context outside the ACT blacklist — an inherent
      #   boundary act, structurally distinct from any act-route call. Its API
      #   accepts only cycle-record shapes, so it cannot carry an arbitrary
      #   write (exemption boundary).
      # - Live-tree-writing governed tools are denied in-process under the
      #   guard (AGT-1: one geometry — live-tree effects go through the
      #   delegated route's scratch area with verdict-gated return; a governed
      #   tool writing the live tree in-process would land pre-verdict).
      # - No bypass: every in-process ACT tool call flows through invoke_tool
      #   with the ACT context, which is where this deny set is enforced.
      module Admission
        class SurfaceError < StandardError; end

        # Governance-store surfaces the mandate may declare, and the governed
        # tools that write each surface. L2 is deliberately absent: it is the
        # free-modification session layer, not a layer-defining store.
        LAYER_WRITE_TOOLS = {
          'l0' => %w[skills_evolve skills_rollback instructions_update system_upgrade],
          'l1' => %w[knowledge_update skills_promote]
        }.freeze

        # Record-store (chain / attestation) writers: never declarable, always
        # denied on the act route regardless of the declared surface.
        RECORD_STORE_TOOLS = %w[
          chain_record chain_import chain_migrate_execute state_commit
          formalization_record attestation_issue attestation_revoke
          l2_attestation_commit l2_attestation_revoke l2_attestation_decline
        ].freeze

        # Governed tools whose effects land in the live project tree. Under
        # the guard these are refused in-process (AGT-1 route symmetry): the
        # act must be expressed as file operations and travel the delegated
        # route, where the scratch area quarantines it until the verdict.
        LIVE_TREE_WRITE_TOOLS = %w[write_section sc_scaffold plugin_project].freeze

        module_function

        # Validate a declared layer surface fail-closed: unknown entries are
        # refused, and any attempt to declare the record store is refused with
        # its own message (AGT-5: never declarable).
        def validate_surface!(layer_surface)
          surface = Array(layer_surface).map(&:to_s)
          surface.each do |layer|
            if %w[record chain attestation].include?(layer)
              raise SurfaceError,
                    "the record store is never declarable (AGT-5): #{layer.inspect}"
            end
            unless LAYER_WRITE_TOOLS.key?(layer)
              raise SurfaceError,
                    "unknown layer surface #{layer.inspect} (declarable: #{LAYER_WRITE_TOOLS.keys.join(', ')})"
            end
          end
          surface
        end

        # Deny set for the ACT invocation context under a declared surface:
        # record-store writers + live-tree writers + every governance writer
        # whose layer is not declared + configured extras.
        def act_blacklist(layer_surface, extra_denied: [])
          surface = validate_surface!(layer_surface)
          denied = RECORD_STORE_TOOLS.dup
          denied.concat(LIVE_TREE_WRITE_TOOLS)
          LAYER_WRITE_TOOLS.each do |layer, tools|
            denied.concat(tools) unless surface.include?(layer)
          end
          denied.concat(Array(extra_denied).map(&:to_s))
          denied.uniq
        end
      end
    end
  end
end
