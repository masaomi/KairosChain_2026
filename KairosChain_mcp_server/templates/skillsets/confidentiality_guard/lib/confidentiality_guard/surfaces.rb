# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module ConfidentialityGuard
      # Crossing classification (design v0.3 CG-2).
      #
      # The surface is defined by the crossing property — content outliving
      # or escaping the conversational context — and these tables are the
      # slice-1 enrollment of instance tools bearing that property. The
      # enrollment obligation is release-gated: test_cg_guard.rb pins these
      # tables against its manifest (CG-2), so extending the tool surface
      # without extending the tables fails the release gate.
      module Surfaces
        module_function

        # Inward persistent-layer writes (crossing class b).
        INWARD_WRITE_TOOLS = {
          'context_save'          => 'l2',
          'context_create_subdir' => 'l2',
          'knowledge_update'      => 'l1',
          'skills_promote'        => 'l1'
        }.freeze

        # Storage-reading tools and how to extract the target path from the
        # call's arguments (crossing class c — guarded only when the policy
        # designates the target as restricted). The raw path is resolved
        # against the tool's workspace root at gate time (Regime), because
        # the external-tools reads resolve relative paths against
        # workspace_root, not the server cwd.
        STORAGE_READ_TOOLS = {
          'safe_file_read' => 'path',
          'safe_file_list' => 'path'
        }.freeze

        # Copy reads a source and writes a destination: the source is a
        # storage-read crossing (a restricted file must not be copied out),
        # and the destination is watched for policy-file edits.
        COPY_TOOLS = {
          'safe_file_copy' => { source: 'source', dest: 'destination' }
        }.freeze

        # Resource-scheme readers (l0://, knowledge://, context://) read the
        # same instance stores by URI, not filesystem path; slice 1 ships no
        # uri-to-path mapping, so under CG-1's coverage clause these are
        # denied wholesale while the regime is active (enforcement-absent
        # read surface). Slice 2 backlog: uri mapping to earn them back.
        UNMAPPED_READ_TOOLS = %w[
          resource_read
          resource_render
        ].freeze

        # Distillation crossings (guard slice-2 first increment, delivered
        # with the chain_distillation track by attended decision 2026-07-22;
        # chain_distillation design v0.5 §5). These two names are the
        # distillation track's release crossings — distillate first, then
        # certificate (CD-1 ordering) — judged per-destination by Verdict
        # instead of the wholesale outward denial. Owned by the guard track;
        # the remainder of the outward class stays denied below.
        DISTILLATION_TOOLS = %w[
          cd_release_distillate
          cd_release_certificate
          cd_release_package
        ].freeze

        # Outward crossings (crossing class a). Slice 1 ships no outward
        # enforcement, so under CG-1's coverage clause every member of this
        # class is denied wholesale while the regime is active. Slice 2
        # earns these back with per-destination verdicts.
        OUTWARD_TOOLS = %w[
          llm_call
          meeting_deposit
          meeting_update_deposit
          meeting_publish_needs
          meeting_attest_skill
          skillset_deposit
          safe_git_push
          chain_export
          philosophy_anchor
        ].freeze

        # File-writing tools, watched to observe edits to the policy files
        # (CG-1: edits are inert until adoption; CG-4: recorded).
        FILE_WRITE_TOOLS = {
          'safe_file_write'  => 'path',
          'safe_file_edit'   => 'path',
          'safe_file_delete' => 'path'
        }.freeze

        # Classify a tool call into a crossing descriptor, or nil when the
        # call does not bear the crossing property at any slice-1 surface.
        # Raw paths are carried unresolved; the Regime resolves them against
        # the tool's workspace root before judging.
        def classify(tool_name, arguments)
          args = arguments.is_a?(Hash) ? arguments : {}
          if (layer = INWARD_WRITE_TOOLS[tool_name])
            return { class: :inward_write, layer: layer, tool: tool_name }
          end
          if (path_key = STORAGE_READ_TOOLS[tool_name])
            # Raw value kept uncoerced: a non-String path resolves to
            # unextractable (denied), never to a stringified literal that
            # silently misses every restricted root.
            return { class: :storage_read, tool: tool_name, raw_path: args[path_key] }
          end
          if (keys = COPY_TOOLS[tool_name])
            return { class: :copy, tool: tool_name,
                     raw_source: args[keys[:source]], raw_dest: args[keys[:dest]] }
          end
          if UNMAPPED_READ_TOOLS.include?(tool_name)
            return { class: :unmapped_read, tool: tool_name }
          end
          if DISTILLATION_TOOLS.include?(tool_name)
            # The certificate identity, when the caller presents one, is an
            # identifier carried into the descriptor so the verdict record
            # cites it (chain_distillation CD-1; identifiers-only, CG-4).
            descriptor = { class: :distillation_outward, tool: tool_name }
            identity = args['certificate_identity']
            descriptor[:certificate_identity] = identity if identity.is_a?(String) && !identity.empty?
            return descriptor
          end
          if OUTWARD_TOOLS.include?(tool_name)
            return { class: :outward, tool: tool_name }
          end
          if (path_key = FILE_WRITE_TOOLS[tool_name])
            return { class: :file_write, tool: tool_name, raw_path: args[path_key] }
          end
          nil
        end
      end
    end
  end
end
