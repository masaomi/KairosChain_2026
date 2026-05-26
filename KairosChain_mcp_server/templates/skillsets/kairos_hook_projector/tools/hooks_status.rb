# frozen_string_literal: true

require 'json'
require_relative '../lib/boot_time_assertion'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      module Tools
        # Read-only inspection of `kairos_hook_projector` state.
        # Wraps its read-only body with a BootTimeAssertion that captures
        # pre/post hash+mtime of projection target files, providing structural
        # (not conventional) guarantee of stage 0 side-effect-zero per design
        # v0.2 §7.2 DoD-0-4 and DoD-0-6.
        #
        # The watched target set in stage 0:
        #   - <project_root>/.claude/settings.json  (Stage 2+ projection target)
        #   - <skillset_root>/plugin/hooks.json     (intermediate target)
        #
        # If either file drifts between pre and post snapshots, the tool
        # raises and the caller receives a fail-fast error rather than a
        # successful response. This is the structural guarantee.
        class HooksStatus < ::KairosMcp::Tools::BaseTool
          SKILLSET_ROOT = File.expand_path('..', __dir__)
          SKILLSET_NAME = 'kairos_hook_projector'
          STAGE_MARKER = 'stage 0 (skeleton + schema + status)'

          def name
            'hooks_status'
          end

          def description
            'Read-only inspection of kairos_hook_projector state. ' \
              'Reports stage, schema location, and mode_hooks document inventory. ' \
              'Structurally guarantees zero side effect on projection targets via ' \
              'a pre/post hash+mtime boot-time assertion (DoD-0-4).'
          end

          def category
            :meta
          end

          def usecase_tags
            %w[hooks status read-only stage0 self-referential]
          end

          def related_tools
            %w[plugin_project skills_audit]
          end

          def input_schema
            {
              type: 'object',
              properties: {},
              additionalProperties: false
            }
          end

          def call(_arguments)
            project_root = resolve_project_root
            watch_paths = compute_watch_paths(project_root)

            assertion = BootTimeAssertion.new(watch_paths: watch_paths)
            assertion.snapshot_pre!

            body = compose_status_body(project_root: project_root,
                                       watch_paths: watch_paths)

            assertion.verify_post!

            text_content(JSON.pretty_generate(
                           body.merge(boot_time_assertion: {
                                        status: 'passed',
                                        watched_paths: watch_paths,
                                        snapshots: assertion.snapshots
                                      })
                         ))
          rescue BootTimeAssertion::StructuralAssertionFailure => e
            text_content(JSON.pretty_generate({
                                                error: 'StructuralAssertionFailure',
                                                detail: e.message,
                                                skillset: SKILLSET_NAME,
                                                stage: STAGE_MARKER
                                              }))
          rescue StandardError => e
            text_content(JSON.pretty_generate({
                                                error: e.class.name,
                                                detail: e.message,
                                                backtrace: e.backtrace&.first(3)
                                              }))
          end

          private

          def resolve_project_root
            if defined?(::KairosMcp) && ::KairosMcp.respond_to?(:project_root)
              ::KairosMcp.project_root
            else
              Dir.pwd
            end
          end

          def compute_watch_paths(project_root)
            [
              File.join(project_root.to_s, '.claude', 'settings.json'),
              File.join(SKILLSET_ROOT, 'plugin', 'hooks.json')
            ]
          end

          def compose_status_body(project_root:, watch_paths:)
            mode_hooks_dir = File.join(SKILLSET_ROOT, 'mode_hooks')
            schema_path = File.join(mode_hooks_dir, '_schema.json')
            mode_files = Dir.glob(File.join(mode_hooks_dir, '*'))
                            .reject { |p| File.basename(p).start_with?('_') }
                            .map { |p| File.basename(p) }
                            .sort

            {
              skillset: SKILLSET_NAME,
              stage: STAGE_MARKER,
              project_root: project_root.to_s,
              schema: {
                path: schema_path,
                present: File.exist?(schema_path)
              },
              mode_hooks: {
                count: mode_files.size,
                files: mode_files
              },
              note: 'Read-only. Stage 0 emits no projections; see ' \
                    'docs/drafts/kairos_hook_projector_design_v0.2_draft.md'
            }
          end
        end
      end
    end
  end
end
