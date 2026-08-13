# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'shellwords'
require_relative '../lib/mode_hooks_compiler'
require_relative '../lib/mode_hooks_locator'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      module Tools
        # Stage 2 activation: compile a mode's declared hooks and install them.
        #
        #   declaration -> compile -> artifact -> .claude/settings.json
        #                                      -> hook_configs/*.json
        #
        # One step. Round 2 tried two — writing this SkillSet's own
        # plugin/hooks.json and letting PluginProjector carry it the rest of the
        # way — and round 2 review rejected that on three counts, each verified:
        # PluginProjector never visited this SkillSet at all (skillset.json has
        # no `plugin` key, so `has_plugin?` is false); `system_upgrade` restored
        # the file from its shipped template, silently discarding an applied and
        # chain-recorded configuration; and `check_installed` reported
        # NOT_INSTALLED for a correct apply, because nothing had reached the
        # harness yet.
        #
        # Writing settings.json directly is what round 1 objected to, so the
        # objection is answered rather than avoided. It was never a contest over
        # the same entries. PluginProjector's `remove_projected_hooks!` rejects
        # only entries whose `_projected_by` equals its own marker
        # ('kairos-chain'); this tool's carry '_projected_by' =>
        # 'kairos_hook_projector'. Neither writer can remove the other's work,
        # and neither can remove a hand-written hook, which carries no marker at
        # all. What remains is a lost-update window between two concurrent
        # applies — real, since the HTTP server runs Puma with five threads, and
        # deliberately left open: the loss is bounded to one mode's entries and
        # the next projection restores them. Compare the round 2 location, where
        # the competing writer was `upgrade`, which knows nothing about
        # ownership and restores an empty file.
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
          # Both keys are required to match before an entry is ours. The first
          # separates this tool from PluginProjector and from hand-written
          # hooks; the second separates one mode from another.
          MARKER_KEY = '_projected_by'
          MARKER = 'kairos_hook_projector'
          OWNER_KEY = '_mode'

          def name
            'mode_hooks_project'
          end

          def description
            "Compile an instruction mode's declared hooks and install them into " \
              '.claude/settings.json, touching only entries this tool placed for ' \
              'this mode. Proposes by default; applying requires echoing back the ' \
              'plan hash.'
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
            config_root = File.join(data_dir, 'hook_configs')
            settings_path = File.join(project_root, '.claude', 'settings.json')

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

            # Substitute into the argument array, then escape and join once. The
            # harness format is a string; Shellwords.join is what makes that
            # string mean the array, whatever the path contains.
            hooks = artifact['hooks'].transform_values do |entries|
              entries.map do |e|
                argv = Array(e['argv']).map do |arg|
                  arg.gsub(ModeHooksCompiler::CONFIG_ROOT, config_root)
                end
                e.reject { |k, _| k == 'argv' }
                 .merge('command' => Shellwords.join(argv))
              end
            end

            { 'hooks' => hooks, 'files' => files,
              'settings_path' => settings_path, 'config_root' => config_root }
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
            current = read_settings(resolved['settings_path'])
            desired = merge_into_settings(current, mode, resolved['hooks'])

            settings_changed = canonical(current) != canonical(desired)
            config_changed = resolved['files'].reject do |path, content|
              File.exist?(path) && File.read(path) == content
            end.keys.map { |p| File.basename(p) }

            {
              desired: desired,
              settings_changed: settings_changed,
              config_changed: config_changed,
              left_alone: count_entries_left_alone(current, mode),
              settings_path: resolved['settings_path'],
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
                                       'settings_path' => resolved['settings_path'],
                                       'settings' => desired,
                                       'files' => resolved['files']
                                     ))
          end

          # An entry is ours only when BOTH markers match. Everything else
          # survives byte for byte: PluginProjector's own entries, another
          # mode's entries, and a hand-written hook, which carries no marker at
          # all and is therefore never ours by construction.
          #
          # Every non-hook key of settings.json survives too. An earlier version
          # rebuilt the file as `{'hooks' => ...}` and dropped `permissions` and
          # everything else with it — the harness configuration is the
          # operator's file, and this tool is a guest in one key of it.
          #
          # That survival is a property of the merge, NOT of the write, and the
          # difference is load-bearing. `apply!` writes the document this merge
          # produced from a read taken earlier, and `record_to_chain` sits
          # between the two taking a lock on the ledger, which can block for as
          # long as another process holds it. Anything written to settings.json
          # inside that window is overwritten by the earlier snapshot. Claude
          # Code writes this file itself — clicking "always allow" on a
          # permission prompt is enough — so the loss is not hypothetical, and
          # it is not bounded to one mode's entries: a `permissions` grant and
          # PluginProjector's groups go the same way, and no later apply
          # restores them, because this tool only rebuilds its own.
          #
          # Left open, 2026-08-13, by the operator, who declined to add a lock
          # or a re-read on the ground that neither is worth the surface area.
          # Recorded here rather than fixed, because a defect the code claims
          # not to have is worse than one it names.
          def ours?(group, mode)
            group.is_a?(Hash) && group[MARKER_KEY] == MARKER && group[OWNER_KEY] == mode
          end

          def merge_into_settings(current, mode, hooks)
            out = deep_dup(current)
            out['hooks'] = (out['hooks'] || {}).each_with_object({}) do |(event, groups), acc|
              kept = Array(groups).reject { |g| ours?(g, mode) }
              acc[event] = kept unless kept.empty?
            end

            hooks.each do |event, entries|
              next if entries.empty?

              out['hooks'][event] ||= []
              out['hooks'][event] << {
                'hooks' => entries, MARKER_KEY => MARKER, OWNER_KEY => mode
              }
            end

            out['hooks'].reject! { |_, v| v.empty? }
            out.delete('hooks') if out['hooks'].empty?
            out
          end

          def count_entries_left_alone(current, mode)
            (current['hooks'] || {}).values.flatten.count { |g| !ours?(g, mode) }
          end

          def deep_dup(value)
            case value
            when Hash then value.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
            when Array then value.map { |v| deep_dup(v) }
            else value
            end
          end

          def proposal(mode, plan, compiled)
            idle = !plan[:settings_changed] && plan[:config_changed].empty?
            # The write set is stated in full, including the config files. An
            # earlier version listed the settings file alone and listed nothing
            # at all for an idle plan, while apply still rewrote every config and
            # chain-recorded — an operator confirming an understated write set.
            writes = []
            writes << plan[:settings_path] if plan[:settings_changed]
            writes.concat(plan[:config_changed].map { |n| File.join(config_dir, n) })
            {
              mode: mode,
              action: 'proposal',
              plan_sha256: plan[:plan_sha256],
              up_to_date: idle,
              settings_changes: plan[:settings_changed] ? plan[:settings_path] : nil,
              config_changes: plan[:config_changed],
              entries_left_alone: plan[:left_alone],
              declared_hooks: compiled.record.dig('output', 'events'),
              writes_if_applied: writes,
              also_records_to_chain: !idle,
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
            FileUtils.mkdir_p(File.dirname(plan[:settings_path]))
            # Referents before the referrer: an interrupted apply leaves an
            # unreferenced config file, never a hook pointing at a config that
            # is not there.
            resolved['files'].each { |path, content| atomic_write(path, content) }
            atomic_write(plan[:settings_path], JSON.pretty_generate(plan[:desired]) + "\n")

            {
              mode: mode,
              action: 'applied',
              settings_file: plan[:settings_path],
              config_files: resolved['files'].keys,
              entries_left_alone: plan[:left_alone],
              chain: chain,
              next_step: 'the hook is live on the next turn; no further step'
            }
          end

          def atomic_write(path, content)
            FileUtils.mkdir_p(File.dirname(path))
            tmp = "#{path}.tmp.#{Process.pid}.#{object_id}"
            File.write(tmp, content)
            File.rename(tmp, path)
          end

          # The constant is nested under KairosMcp, and every other SkillSet in
          # the tree spells it that way. These two lines were the only top-level
          # ::KairosChain:: references anywhere, so the guard was always false,
          # apply! always returned refused_unrecorded, and stage 2 activation had
          # never once succeeded — not for a consumer and not here. The write
          # path is five lines; the defect was one word, and it survived because
          # the test double replaces this whole method, so the real one had never
          # run. test_the_real_recorder_records_and_reports_the_block drives it.
          def record_to_chain(mode, compiled)
            return { recorded: false, reason: 'KairosMcp::KairosChain::Chain unavailable' } unless
              defined?(::KairosMcp::KairosChain::Chain)

            block = ::KairosMcp::KairosChain::Chain.new.add_block(
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

          # Every shape this can return is one merge_into_settings can consume.
          # Type-checking the top level alone let `{"hooks": []}` and
          # `{"hooks":{"Stop":[null]}}` raise out of the tool as an error rather
          # than as the refusal Inv-C1 requires, and once raised the tool could
          # never repair the file it had refused.
          # A shape this tool cannot merge is a refusal, the same as JSON it
          # cannot parse. The earlier version dropped what it could not use — a
          # non-object top level, a non-object `hooks`, an event whose value is
          # not an array, a non-object group — and the proposal said nothing
          # about the loss. That is operator content, and this tool does not own
          # it; content it cannot preserve it must decline to rewrite.
          def read_settings(path)
            return {} unless File.exist?(path)

            parsed = JSON.parse(File.read(path))
            raise "#{path}: the top level is not an object; refusing to rewrite it" unless
              parsed.is_a?(Hash)

            hooks = parsed['hooks']
            return parsed if hooks.nil?
            raise "#{path}: `hooks` is not an object; refusing to rewrite it" unless
              hooks.is_a?(Hash)

            hooks.each do |event, groups|
              raise "#{path}: hooks.#{event} is not an array; refusing to rewrite it" unless
                groups.is_a?(Array)

              bad = groups.each_index.reject { |i| groups[i].is_a?(Hash) }
              raise "#{path}: hooks.#{event}[#{bad.first}] is not an object; " \
                    'refusing to rewrite it' unless bad.empty?
            end

            parsed
          rescue JSON::ParserError
            raise "#{path} is not valid JSON; refusing to rewrite it"
          end

          def load_document(mode, body_path = nil)
            ModeHooksLocator.load(
              ModeHooksLocator.find(mode, skillset_root: SKILLSET_ROOT, mode_body_path: body_path)
            )
          end

          def config_dir
            File.join(data_dir, 'hook_configs')
          end

          # Same resolution as hooks_status and mode_hooks_validate, so the
          # settings file this writes is the one the boot-time assertion
          # watches. Round 2's target was built from the tool file's own
          # location instead, and the two paths only coincided when the tool ran
          # from an installed SkillSet.
          def project_root
            if defined?(::KairosMcp) && ::KairosMcp.respond_to?(:project_root)
              ::KairosMcp.project_root.to_s
            else
              Dir.pwd
            end
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
