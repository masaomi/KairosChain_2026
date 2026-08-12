# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require_relative '../lib/mode_hooks_compiler'
require_relative '../lib/mode_hooks_locator'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      module Tools
        # Stage 2 activation: hand a mode's compiled hooks to the projection
        # pipeline that already exists.
        #
        # This tool does NOT write the harness configuration. Round 1 review
        # found that an earlier version did, making it a second independent
        # writer to `.claude/settings.json` alongside PluginProjector's — two
        # uncoordinated read-modify-write cycles on one file, which loses an
        # update whenever they overlap, and which v0.2 Inv-2 exists to forbid.
        #
        # What it writes instead is this SkillSet's own `plugin/hooks.json`,
        # which PluginProjector already reads and merges. One writer reaches
        # settings.json; this tool reaches only its own SkillSet, which is what
        # Inv-1 asked for all along.
        #
        #   declaration -> compile -> plugin/hooks.json + hook_configs/
        #                                   |
        #                            PluginProjector (the one writer)
        #                                   |
        #                            .claude/settings.json
        #
        # Three properties make the write safe to hand to a machine:
        #
        #   1. Propose by default. The normal call reports the diff and writes
        #      nothing.
        #   2. Confirmation is binding and covers the whole plan — artifact,
        #      declaration, and every resolved target path. A declaration edited
        #      between proposal and apply is refused.
        #   3. Every path is contained. The mode identity reaches a filename, so
        #      it is checked as a path segment before it is joined, and each
        #      resolved target is checked against its root before it is written.
        class ModeHooksProject < ::KairosMcp::Tools::BaseTool
          SKILLSET_ROOT = File.expand_path('..', __dir__)
          SKILLSET_NAME = 'kairos_hook_projector'
          OWNER_KEY = '_mode'

          def name
            'mode_hooks_project'
          end

          def description
            "Compile an instruction mode's declared hooks and hand them to the " \
              'existing projection pipeline by writing this SkillSet\'s own ' \
              'plugin/hooks.json. Never writes the harness configuration — ' \
              'PluginProjector remains the single writer there. Proposes by ' \
              'default; applying requires echoing back the plan hash.'
          end

          def category
            :meta
          end

          def usecase_tags
            %w[hooks projection instruction-mode stage2]
          end

          def related_tools
            %w[mode_hooks_validate hooks_status plugin_project]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                mode: { type: 'string',
                        description: 'Instruction mode name. Defaults to the active mode.' },
                apply: { type: 'boolean', default: false,
                         description: 'False (default) proposes and writes nothing.' },
                confirm_sha256: { type: 'string',
                                  description: 'The plan_sha256 shown by the proposal.' }
              },
              additionalProperties: false
            }
          end

          def call(arguments)
            text_content(JSON.pretty_generate(run(arguments || {})))
          rescue StandardError => e
            text_content(JSON.pretty_generate(error: e.class.name, detail: e.message,
                                              backtrace: e.backtrace&.first(3)))
          end

          private

          def run(args)
            mode = args['mode'] || active_mode
            return { error: 'no_active_mode' } if mode.nil? || mode == 'none'

            body_path = mode_body_path(mode)
            return { mode: mode, error: 'mode_body_not_found', looked_at: body_path } unless
              body_path && File.exist?(body_path)

            document = load_document(mode, body_path)
            compiled = ModeHooksCompiler.new.compile(
              mode_name: mode, document: document, mode_body: File.read(body_path)
            )

            if compiled.refused?
              return { mode: mode, action: 'refused',
                       refusal: compiled.record['refusal'], nothing_written: true }
            end

            resolved = resolve(mode, compiled.artifact)
            # resolve returns either the resolved plan (string keys) or a
            # refusal (symbol keys). Testing only for :error let a containment
            # refusal fall through into planning, where it surfaced as a
            # TypeError instead of the refusal it was.
            return resolved if resolved[:error] || resolved[:action]

            plan = plan_for(mode, resolved, compiled)
            return proposal(mode, plan, compiled) unless args['apply']

            if args['confirm_sha256'] != plan[:plan_sha256]
              return { mode: mode, action: 'refused_confirmation',
                       expected: plan[:plan_sha256], received: args['confirm_sha256'],
                       nothing_written: true,
                       note: 'the plan changed since the proposal, or the wrong hash was ' \
                             'echoed. Re-run without apply and confirm the current plan.' }
            end

            apply!(mode, resolved, plan, compiled)
          end

          # --- resolution, contained ----------------------------------------

          def resolve(mode, artifact)
            skillset_dir = installed_skillset_dir
            config_root = File.join(data_dir, 'hook_configs')
            hooks_path = File.join(skillset_dir, 'plugin', 'hooks.json')

            files = {}
            artifact['files'].each do |name, content|
              path = File.join(config_root, name)
              unless contained?(config_root, path)
                return { mode: mode, action: 'refused', nothing_written: true,
                         refusal: { 'category' => 'unsafe_path',
                                    'detail' => "config #{name.inspect} resolves outside " \
                                                "#{config_root}" } }
              end
              files[path] = content
            end

            hooks = artifact['hooks'].transform_values do |entries|
              entries.map do |e|
                e.merge('command' => e['command'].gsub(ModeHooksCompiler::CONFIG_ROOT, config_root))
              end
            end

            { 'hooks' => hooks, 'files' => files,
              'hooks_path' => hooks_path, 'config_root' => config_root }
          end

          # The mode identity already passed PathContainment.safe_segment? in the
          # compiler; this is the second half — the resolved target, checked
          # against the root it must stay under. Both halves are needed: a safe
          # segment can still land outside via a symlinked root.
          # Creates nothing. An earlier version made the root before checking,
          # which meant a proposal — the call that promises to write nothing —
          # created a directory.
          #
          # Two questions, both required. Lexically, is the target under the
          # root it was built from? And does the deepest part of that path that
          # actually exists still sit under the store, once symlinks are
          # resolved? The first alone misses a symlinked ancestor; the second
          # alone cannot speak about a path not yet created.
          def contained?(root, path)
            target = File.expand_path(path)
            return false if target.split(File::SEPARATOR).include?('..')
            return false unless target.start_with?(File.expand_path(root) + File::SEPARATOR)

            # The symlink half needs the core's containment check, which
            # resolves the literal path rather than a lexically collapsed one.
            # It is present whenever this runs inside the server, which is
            # where the write happens. Outside it — a bare `ruby -r` harness —
            # only the lexical half is asserted, and this says so rather than
            # implying a guarantee it did not establish.
            return true unless defined?(::KairosMcp::PathContainment)

            anchor = root
            anchor = File.dirname(anchor) until File.directory?(anchor) || anchor == '/'
            return false unless File.directory?(anchor)

            ::KairosMcp::PathContainment.contained?(anchor, target)
          rescue StandardError
            false
          end

          # --- planning ------------------------------------------------------

          def plan_for(mode, resolved, compiled)
            current = read_hooks_file(resolved['hooks_path'])
            desired = merge_into_hooks_file(current, mode, resolved['hooks'])

            hooks_changed = canonical(current) != canonical(desired)
            config_changed = resolved['files'].reject do |path, content|
              File.exist?(path) && File.read(path) == content
            end.keys.map { |p| File.basename(p) }

            foreign = count_foreign_entries(current, mode)

            {
              desired: desired,
              hooks_changed: hooks_changed,
              config_changed: config_changed,
              foreign_entries: foreign,
              hooks_path: resolved['hooks_path'],
              plan_sha256: plan_hash(resolved, desired, compiled)
            }
          end

          # Binds everything an operator is agreeing to: the compiled artifact,
          # the declaration it came from, the exact file contents, and the exact
          # target paths. The earlier version bound the artifact hash alone, so
          # editing the declaration's version or binding preserved the hash and
          # a stale confirmation was accepted.
          def plan_hash(resolved, desired, compiled)
            Digest::SHA256.hexdigest(canonical(
                                       'artifact' => compiled.record['output'],
                                       'document' => compiled.record['input'],
                                       'hooks_path' => resolved['hooks_path'],
                                       'hooks' => desired,
                                       'files' => resolved['files']
                                     ))
          end

          # We own this file, but a future version of this SkillSet may ship
          # static hooks in it. Entries carrying no owner key are left alone.
          def merge_into_hooks_file(current, mode, hooks)
            out = { 'hooks' => {} }
            (current['hooks'] || {}).each do |event, entries|
              kept = Array(entries).reject { |e| e[OWNER_KEY] == mode }
              out['hooks'][event] = kept unless kept.empty?
            end
            # PluginProjector reads hooks.json as event -> array of GROUPS, each
            # group carrying its own `hooks` array. Emitting the commands
            # directly at group level produced a file the projector would merge
            # into settings.json in a shape the harness does not understand.
            hooks.each do |event, entries|
              next if entries.empty?

              out['hooks'][event] ||= []
              out['hooks'][event] << { 'hooks' => entries, OWNER_KEY => mode }
            end
            out['hooks'].reject! { |_, v| v.empty? }
            out
          end

          def count_foreign_entries(current, mode)
            (current['hooks'] || {}).values.flatten.count { |e| e[OWNER_KEY] != mode }
          end

          def proposal(mode, plan, compiled)
            idle = !plan[:hooks_changed] && plan[:config_changed].empty?
            {
              mode: mode,
              action: 'proposal',
              plan_sha256: plan[:plan_sha256],
              up_to_date: idle,
              hooks_file_changes: plan[:hooks_changed] ? plan[:hooks_path] : nil,
              config_changes: plan[:config_changed],
              entries_left_alone: plan[:foreign_entries],
              declared_hooks: compiled.record.dig('output', 'events'),
              writes_if_applied: idle ? [] : [plan[:hooks_path]],
              projection_still_required: 'PluginProjector publishes this to the harness; ' \
                                         'run plugin_project after applying',
              to_apply: idle ? 'nothing to apply' :
                        "call again with apply=true and confirm_sha256=#{plan[:plan_sha256]}",
              nothing_written: true
            }
          end

          # --- application ---------------------------------------------------

          def apply!(mode, resolved, plan, compiled)
            # Record before anything is created, not merely before the file
            # contents are written: making the directories first left them
            # behind on a refusal, which is a change to disk on a path that
            # promised none. Inv-7nr.
            #
            # Record before the write, not after. The earlier version wrote
            # first and returned "applied" even when recording failed, so a
            # hook-composition change could land on disk unrecorded — which
            # v0.2 Inv-7 covers and Inv-7nr forbids losing.
            chain = record_to_chain(mode, compiled)
            unless chain[:recorded]
              return { mode: mode, action: 'refused_unrecorded', chain: chain,
                       nothing_written: true,
                       note: 'a hook-composition change is not applied unless it can be ' \
                             'recorded first. Inv-7nr.' }
            end

            FileUtils.mkdir_p(resolved['config_root'])
            FileUtils.mkdir_p(File.dirname(plan[:hooks_path]))
            resolved['files'].each { |path, content| atomic_write(path, content) }
            atomic_write(plan[:hooks_path], JSON.pretty_generate(plan[:desired]) + "\n")

            {
              mode: mode,
              action: 'applied',
              hooks_file: plan[:hooks_path],
              config_files: resolved['files'].keys,
              entries_left_alone: plan[:foreign_entries],
              chain: chain,
              next_step: 'run plugin_project to publish this to the harness configuration'
            }
          end

          def atomic_write(path, content)
            FileUtils.mkdir_p(File.dirname(path))
            tmp = "#{path}.tmp.#{Process.pid}.#{object_id}"
            File.write(tmp, content)
            File.rename(tmp, path)
          end

          def record_to_chain(mode, compiled)
            return { recorded: false, reason: 'KairosChain::Chain unavailable' } unless
              defined?(::KairosChain::Chain)

            block = ::KairosChain::Chain.new.add_block(
              ["mode_hooks_project mode=#{mode}", JSON.generate(compiled.record)]
            )
            { recorded: true, block_index: block.index, hash: block.hash }
          rescue StandardError => e
            { recorded: false, reason: "#{e.class}: #{e.message}" }
          end

          # --- environment ----------------------------------------------------

          def canonical(value)
            ModeHooksCompiler.new.canonical_json(value)
          end

          def read_hooks_file(path)
            return { 'hooks' => {} } unless File.exist?(path)

            parsed = JSON.parse(File.read(path))
            parsed.is_a?(Hash) ? parsed : { 'hooks' => {} }
          rescue JSON::ParserError
            raise "#{path} is not valid JSON; refusing to rewrite it"
          end

          def load_document(mode, body_path = nil)
            ModeHooksLocator.load(
              ModeHooksLocator.find(mode, skillset_root: SKILLSET_ROOT, mode_body_path: body_path)
            )
          end

          def installed_skillset_dir
            File.join(data_dir, 'skillsets', SKILLSET_NAME)
          end

          def data_dir
            if defined?(::KairosMcp) && ::KairosMcp.respond_to?(:data_dir)
              ::KairosMcp.data_dir.to_s
            else
              File.join(Dir.pwd, '.kairos')
            end
          end

          def active_mode
            ::KairosMcp::SkillsConfig.load['instructions_mode']
          rescue StandardError
            nil
          end

          def mode_body_path(mode)
            case mode
            when 'developer' then ::KairosMcp.md_path
            when 'user'      then ::KairosMcp.quickguide_path
            when 'tutorial'  then ::KairosMcp.tutorial_path
            else File.join(::KairosMcp.skills_dir, "#{mode}.md")
            end
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
