# frozen_string_literal: true

require 'json'
require_relative '../lib/boot_time_assertion'
require_relative '../lib/mode_hooks_locator'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      module Tools
        # Read-only inspection of `kairos_hook_projector` state: stage, schema
        # presence, and the mode_hooks declarations ModeHooksLocator resolves.
        # The body runs inside a BootTimeAssertion that captures pre/post
        # hash+mtime of the projection target, so if that file drifts between
        # the snapshots the tool raises instead of returning success — a
        # structural, not conventional, guarantee that this call wrote nothing.
        class HooksStatus < ::KairosMcp::Tools::BaseTool
          SKILLSET_ROOT = File.expand_path('..', __dir__)
          SKILLSET_NAME = 'kairos_hook_projector'
          STAGE_MARKER = 'stage 2 (compile + validate + gated projection)'

          def name
            'hooks_status'
          end

          def description
            'Read-only inspection of kairos_hook_projector state. ' \
              'Reports stage, schema location, and the mode_hooks declarations ' \
              'found for each mode. Structurally guarantees zero side effect on ' \
              'the projection target via a pre/post hash+mtime boot-time assertion.'
          end

          def category
            :meta
          end

          def usecase_tags
            %w[hooks status read-only stage2 self-referential]
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
                                        # Derived, not asserted. This was the
                                        # literal 'passed', so deleting the
                                        # verify_post! call above left the tool
                                        # reporting a verification it had not
                                        # performed, and no test could see it.
                                        status: assertion.snapshots[:post] ? 'passed' : 'not_verified',
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
              # The one file a read-only tool must be shown not to have touched.
              # `plugin/hooks.json` was the round 2 write target and is watched
              # no longer — it was also built from this file's own location
              # rather than the instance data directory, so it only named the
              # real target when the tool ran from an installed SkillSet.
              # `hook_configs/` is still unwatched: the assertion takes explicit
              # paths and the per-gate filenames are not known before a compile.
              File.join(project_root.to_s, '.claude', 'settings.json')
            ]
          end

          def compose_status_body(project_root:, watch_paths:)
            schema_path = File.join(SKILLSET_ROOT, 'mode_hooks', '_schema.json')
            bodies, enumeration_error = mode_bodies
            declarations = bodies.filter_map do |mode, body_path|
              ModeHooksLocator.find(mode, skillset_root: SKILLSET_ROOT,
                                          mode_body_path: body_path)
            end.sort

            {
              skillset: SKILLSET_NAME,
              stage: STAGE_MARKER,
              project_root: project_root.to_s,
              schema: {
                path: schema_path,
                present: File.exist?(schema_path)
              },
              # "I could not look" is not "there is nothing": when the
              # enumeration itself failed, no count is claimed — the body
              # names the failure instead. This is the same principle as
              # mode_hooks_validate's UNKNOWN_INSTALLED verdict for a
              # settings file it could not read.
              mode_hooks: if enumeration_error
                            { enumeration_error: enumeration_error }
                          else
                            { count: declarations.size, files: declarations }
                          end,
              note: 'Read-only. To declare or install hooks: ' \
                    'mode_hooks_validate, then mode_hooks_project.'
            }
          end

          # One entry per mode that has a body: the three fixed bodies, then
          # every <mode>.md under the instance skills directory (fixed names
          # win a collision, matching mode_hooks_validate's resolution).
          # Declarations are then found by ModeHooksLocator — the same lookup
          # the compile path uses — so the inventory names the files that
          # actually resolve. The earlier version globbed this SkillSet's own
          # mode_hooks/ directory, which ships only underscore-prefixed
          # non-modes, and reported count 0 while a projected hook was live.
          #
          # Returns [entries, error]. One raising accessor wipes the whole
          # enumeration, so the error string rides beside the (then empty)
          # entries: an earlier version rescued to a bare [] here, and the
          # tool reported count 0 as fact when it had not been able to look.
          def mode_bodies
            fixed = { 'developer' => :md_path, 'user' => :quickguide_path,
                      'tutorial' => :tutorial_path }.filter_map do |mode, accessor|
              path = ::KairosMcp.respond_to?(accessor) && ::KairosMcp.public_send(accessor)
              [mode, path.to_s] if path
            end
            skills = ::KairosMcp.respond_to?(:skills_dir) && ::KairosMcp.skills_dir
            # Dir.children, not Dir.glob. glob's failure mode is silence: on an
            # unreadable directory it returns [] (children raises Errno::EACCES,
            # which the rescue below converts to enumeration_error), and on a
            # path containing glob metacharacters ([ ] { } * ?) it matches
            # nothing — both read back as "count: 0" stated as fact. children
            # does no pattern matching, so metacharacter paths resolve. The
            # narrow rescue keeps glob's one truthful empty: a configured but
            # absent skills dir is "no custom bodies", not a failed look —
            # skills_dir is a joined path, never created by the accessor.
            # Dotfiles are skipped as glob skipped them (macOS ._x.md doubles).
            custom = begin
              skills ? Dir.children(skills.to_s)
                          .select { |f| f.end_with?('.md') && !f.start_with?('.') }
                          .map { |f| [File.basename(f, '.md'), File.join(skills.to_s, f)] } : []
            rescue Errno::ENOENT, Errno::ENOTDIR
              []
            end
            [(fixed + custom).uniq { |mode, _| mode }, nil]
          rescue StandardError => e
            [[], "#{e.class.name}: #{e.message}"]
          end
        end
      end
    end
  end
end
