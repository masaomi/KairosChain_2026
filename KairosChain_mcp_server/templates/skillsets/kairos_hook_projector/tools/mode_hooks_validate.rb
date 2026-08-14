# frozen_string_literal: true

require 'json'
require 'digest'
require 'shellwords'
require_relative '../lib/boot_time_assertion'
require_relative '../lib/mode_hooks_compiler'
require_relative '../lib/mode_hooks_locator'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      module Tools
        # Read-only validation of an instruction mode against its mode_hooks
        # declaration. Answers four questions, in decreasing order of how often
        # they go wrong:
        #
        #   1. drift      — has the mode body moved on since the declaration
        #                   was authored? (masa.md changelog v0.4.4 records this
        #                   exact failure: two bodies shared version 0.4.3 and a
        #                   re-projection silently dropped one line of edits.)
        #   2. installed  — does what the declaration compiles to match what is
        #                   actually installed in the harness config right now?
        #   3. resolvable — does the declaration compile at all?
        #   4. declared   — does a declaration exist, and which sections carry a
        #                   machine-checkable limit but have no decision recorded?
        #
        # Question 4 never fails the validation. Whether a section deserves a
        # gate is an authorial judgment; this tool can only surface candidates
        # and record that the author already answered (via `not_gated`).
        #
        # Structurally read-only: the body runs inside a BootTimeAssertion over
        # the harness config and the projection targets, so any write — by this
        # tool or by anything it calls — raises instead of returning success.
        class ModeHooksValidate < ::KairosMcp::Tools::BaseTool
          SKILLSET_ROOT = File.expand_path('..', __dir__)
          SKILLSET_NAME = 'kairos_hook_projector'

          # A section stating a quantity with a unit is a candidate for a gate.
          # Advisory only, and deliberately narrow: on masa.md v0.4.6 this flags
          # 3 of 53 sections, two of them genuinely gateable. Widening it to
          # absolute words (必ず / never / must not) flags 24 of 53, which is a
          # list nobody reads.
          #
          # Known blind spot: it finds limits on the SHAPE OF OUTPUT only. A
          # section whose rule is procedural — "call these tools at session
          # start" — is checkable against the tool-call sequence but states no
          # number, so it will never appear here. Those must be declared by hand.
          LIMIT_HINT = /
            \d+\s*(?:行|個|枚|文字) |
            \d+\s*(?:lines?|items?|tables?|headings?|words?)
          /xi

          def name
            'mode_hooks_validate'
          end

          def description
            'Read-only validation of an instruction mode against its mode_hooks ' \
              'declaration: drift between the mode body and the declaration, ' \
              'divergence between the declaration and the installed harness hooks, ' \
              'compile resolvability, and sections carrying a machine-checkable ' \
              'limit for which no gate decision has been recorded.'
          end

          def category
            :meta
          end

          def usecase_tags
            %w[hooks validation drift read-only instruction-mode]
          end

          def related_tools
            %w[hooks_status plugin_project instructions_update]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                mode: {
                  type: 'string',
                  description: 'Instruction mode name. Defaults to the active mode ' \
                               'from instructions_mode in the skills config.'
                }
              },
              additionalProperties: false
            }
          end

          def call(arguments)
            project_root = resolve_project_root
            watch = watch_paths(project_root)

            assertion = BootTimeAssertion.new(watch_paths: watch)
            assertion.snapshot_pre!
            body = validate(arguments['mode'], project_root)
            assertion.verify_post!

            # Reported, not merely performed. Without this the assertion was
            # unfalsifiable from outside: deleting either call left the tool
            # returning the same body, and the only test of it passed because
            # this tool does not write — not because anything had verified.
            # Derived from the post snapshot, so a deleted verify_post! shows.
            text_content(JSON.pretty_generate(
                           body.merge(boot_time_assertion: {
                                        status: assertion.snapshots[:post] ? 'passed' : 'not_verified',
                                        watched_paths: watch
                                      })
                         ))
          rescue BootTimeAssertion::StructuralAssertionFailure => e
            text_content(JSON.pretty_generate(
                           error: 'StructuralAssertionFailure', detail: e.message,
                           skillset: SKILLSET_NAME
                         ))
          rescue StandardError => e
            text_content(JSON.pretty_generate(
                           error: e.class.name, detail: e.message,
                           backtrace: e.backtrace&.first(3)
                         ))
          end

          private

          def validate(requested_mode, project_root)
            mode = requested_mode || active_mode
            return { error: 'no_active_mode' } if mode.nil? || mode == 'none'

            body_path = mode_body_path(mode)
            unless body_path && File.exist?(body_path)
              return { mode: mode, error: 'mode_body_not_found', looked_at: body_path }
            end

            body = File.read(body_path, encoding: 'UTF-8')
            doc_path = document_path(mode, body_path)
            document = doc_path ? load_document(doc_path) : nil

            checks = {}
            checks[:declared] = check_declared(document, doc_path, body)
            checks[:drift] = check_drift(document, body, body_path)
            compiled = compile(mode, document, body)
            checks[:resolvable] = check_resolvable(compiled)
            checks[:installed] = check_installed(compiled, project_root, mode)

            {
              mode: mode,
              mode_body: { path: body_path,
                           version: declared_version(body),
                           sha256: Digest::SHA256.hexdigest(body) },
              declaration: doc_path,
              checks: checks,
              verdict: verdict(checks)
            }
          end

          # --- individual checks -------------------------------------------

          def check_declared(document, doc_path, body)
            if document.nil?
              return {
                status: 'open',
                detail: 'no mode_hooks document for this mode; nothing is gated',
                candidate_sections: candidates(body, [], [])
              }
            end

            gated = gated_sections(document)
            declined = Array(document['not_gated']).map { |e| e['section'] }
            open = candidates(body, gated, declined)
            {
              status: open.empty? ? 'ok' : 'open',
              gated_sections: gated,
              declined_sections: declined,
              candidate_sections: open,
              detail: open.empty? ? 'every candidate section has a recorded decision' :
                      "#{open.size} section(s) carry a checkable limit with no recorded decision"
            }
          end

          def check_drift(document, body, body_path)
            binding = document && document['binding']
            return { status: 'unknown', detail: 'declaration carries no binding' } if binding.nil?

            actual = Digest::SHA256.hexdigest(body)
            expected = binding['mode_body_sha256']
            body_version = declared_version(body)

            problems = []
            if expected && expected != actual
              problems << "body sha256 #{actual[0, 12]}… != declared #{expected[0, 12]}…"
            end
            if binding['mode_version'] && body_version && binding['mode_version'] != body_version
              problems << "body version #{body_version} != declared #{binding['mode_version']}"
            end
            if problems.empty?
              { status: 'ok', detail: "declaration matches #{File.basename(body_path)}" }
            else
              { status: 'drift', detail: problems.join('; '),
                remedy: 'revisit the declaration against the changed section, ' \
                        'then update binding.mode_body_sha256 and mode_version' }
            end
          end

          def check_resolvable(compiled)
            return { status: 'skipped', detail: 'no declaration' } if compiled.nil?

            if compiled.refused?
              { status: 'refused',
                category: compiled.record.dig('refusal', 'category'),
                detail: compiled.record.dig('refusal', 'detail') }
            else
              { status: 'ok',
                hook_count: compiled.record.dig('output', 'hook_count'),
                events: compiled.record.dig('output', 'events') }
            end
          end

          # Ownership is an AND of two markers and this is the reader's half of
          # it. Matching a config basename alone accepted a group placed by
          # anything at all — another tool, a hand-written hook — as evidence
          # that this mode's projection was installed.
          MARKER_KEY = '_projected_by'
          MARKER = 'kairos_hook_projector'
          OWNER_KEY = '_mode'

          def ours?(group, mode)
            group.is_a?(Hash) && group[MARKER_KEY] == MARKER && group[OWNER_KEY] == mode
          end

          # An installed command is the Shellwords join of an argv, so the
          # config argument is recovered by splitting it back and compared
          # whole. Substring inclusion matched in both directions a basename
          # that merely contains the declared one — `readable_gate.0.json.bak`
          # passed for `readable_gate.0.json`. The full path is returned, not
          # its basename: an earlier version threw the path away, so a config
          # that had been moved or deleted still validated as `installed: ok`
          # while the gate it configured found nothing and enforced nothing.
          # A command that names no config, or cannot be split, yields nil and
          # matches nothing.
          def config_path(command)
            Shellwords.split(command.to_s)
                      .find { |a| File.basename(a).end_with?('.json') }
          rescue ArgumentError
            nil
          end

          # The full command the projector would install for a declared argv:
          # the Shellwords join of the whole substituted array, executable and
          # every flag included — the same string resolve() hands the harness.
          # The artifact's argv carries CONFIG_ROOT as a token, not a resolved
          # path, so the substitution root here is the one fact validate has
          # always trusted: the config root the installed command itself
          # carries. Round 8 compared ownership, the config BASENAME, and the
          # config BYTES, and never the command around them, so an owned
          # `/bin/true --config <the correct config>` read `installed: ok`
          # while the gate never ran. Comparing the whole command tightens the
          # existing equality — plan_for already compares full command strings
          # inside its settings comparison, so this closes the
          # executable-element route on which the two tools could disagree.
          def expected_command(argv, installed_config_path)
            root = File.dirname(installed_config_path)
            Shellwords.join(Array(argv).map do |a|
              a.to_s.gsub(ModeHooksCompiler::CONFIG_ROOT, root)
            end)
          end

          # The bytes of a config file, or nil for anything the gate itself
          # could not read there: a missing file, a directory, an unreadable
          # one. Round 8 read with a bare File.read, and one chmod-000 config
          # collapsed the whole answer into `{"error":"Errno::EACCES"}` — no
          # verdict, no drift check, no resolvability check, and no
          # boot_time_assertion marker, since call's rescue sits outside
          # verify_post!. Unreadable degrades the one check that looked, the
          # same way absent always has.
          def config_bytes(path)
            return nil unless File.file?(path)

            File.read(path, encoding: 'UTF-8')
          rescue SystemCallError
            nil
          end

          # The hooks table of the settings file, or nil plus the reason.
          # What reaches this rescue through the tool surface is the
          # parse-and-shape family: unparseable JSON (a trailing comma, zero
          # bytes, a truncation), a top level that is not an object, or a
          # `hooks` value that is not an object. A file the read itself
          # refuses — chmod 000, a directory at the path — never arrives
          # here through call: BootTimeAssertion#snapshot hashes this same
          # watched file inside snapshot_pre!, before validate is entered,
          # so the SystemCallError surfaces from there as an error body — no
          # verdict, no checks, no boot_time_assertion marker. Measured in
          # round 10 through the real call, both states; the same states
          # driven at the check level, below the assertion, degrade cleanly,
          # which is what the SystemCallError arm below is for. Whether the
          # surface should answer with a verdict when the watched path
          # itself is unhashable is an operator question about what the
          # structural assertion means, not something this rescue decides.
          # config_bytes above is the round 8 repair of this exact shape for
          # CONFIG files; the settings file — this tool's actual subject,
          # and the one Claude Code writes itself — kept the bare
          # JSON.parse(File.read(...)), so one trailing comma collapsed the
          # whole answer into an error body of the same kind, because call's
          # rescue sits outside verify_post!. What cannot be read as a
          # settings object degrades to the `unknown` an absent settings
          # file has always produced — in both states what is installed
          # cannot be determined, and the UNKNOWN_INSTALLED verdict already
          # says unanswered is not OK.
          def settings_hooks(path)
            parsed = JSON.parse(File.read(path, encoding: 'UTF-8'))
            return [nil, "top level is #{parsed.class}, not an object"] unless parsed.is_a?(Hash)

            hooks = parsed['hooks'] || {}
            return [nil, "`hooks` is #{hooks.class}, not an object"] unless hooks.is_a?(Hash)

            [hooks, nil]
          rescue JSON::ParserError, SystemCallError => e
            [nil, e.message]
          end

          # What the declaration compiles to vs what the harness actually runs,
          # in both directions. The forward direction — every declared hook is
          # installed — was already checked. The reverse was not: emptying a
          # declaration reported `nothing_declared` while the gate it used to
          # declare stayed in settings.json and went on blocking turns, and the
          # operator was told nothing was wrong.
          def check_installed(compiled, project_root, mode)
            settings_path = File.join(project_root.to_s, '.claude', 'settings.json')
            unless File.exist?(settings_path)
              return { status: 'unknown', detail: 'no .claude/settings.json' }
            end

            installed, unreadable = settings_hooks(settings_path)
            if installed.nil?
              # DD-16 (round 10): this was the only non-ok installed status
              # shipping no remedy — the operator got UNKNOWN_INSTALLED, a
              # reason, and no instruction. The remedy cannot be the three
              # siblings' "run the mode_hooks_project tool": the projector's
              # read_settings raises "refusing to rewrite it" on exactly
              # these inputs. The honest instruction is hand repair, guided
              # by the reason the detail carries.
              return { status: 'unknown',
                       detail: "#{settings_path} cannot be read as a settings object " \
                               "(#{unreadable}); what is installed cannot be determined",
                       remedy: 'repair the settings file by hand — the detail names ' \
                               'the file and, for a parse error, the position of the ' \
                               'typo; the mode_hooks_project tool refuses to rewrite ' \
                               'what it cannot read as settings. A file this process ' \
                               'cannot read at all needs its access restored first, ' \
                               'and that repair may not be yours to make' }
            end

            wanted = compiled&.compiled? ? compiled.artifact['hooks'] : {}
            # The expected bytes come with the artifact: `files` maps each
            # config basename to the canonical JSON the projector writes
            # verbatim, so equality against a file on disk here is the same
            # equality plan_for applies when it decides config_changed. The
            # `|| {}` covers artifact-shaped doubles that carry no files key.
            wanted_files = compiled&.compiled? ? compiled.artifact['files'] || {} : {}

            missing = []
            wanted_argv = {}
            wanted.each do |event, entries|
              entries.each do |entry|
                # The artifact carries a structured argument array, so the
                # config filename is an element rather than something to parse
                # out of a sentence. Two earlier versions extracted it with a
                # regex over the joined string: the first matched `*.py` and
                # broke silently when the interpreter was unpinned, leaving
                # `include?("")` true for every hook on the event. Reading the
                # element cannot fail that way. A missing element still refuses
                # rather than matching everything.
                marker = Array(entry['argv']).map { |a| File.basename(a.to_s) }
                                             .find { |a| a.end_with?('.json') }
                wanted_argv[marker] = entry['argv'] if marker
                # Present means enforcing: the installed command must BE the
                # declared one — the full expected command, not merely one
                # naming the declared config — over a file still readable at
                # the path the command carries, with the bytes the declaration
                # compiles to. Byte equality alone left the executable and
                # every other argument uncompared, so an owned
                # `/bin/true --config <the correct config>` reported
                # `installed: ok` while nothing enforced (round 9, N1). The
                # filename encodes mode, event, gate, and position and nothing
                # else, so name-plus-existence reported `installed: ok` across
                # every parameter change — while the projector, comparing the
                # same bytes, correctly reported a pending write. A marker the
                # artifact carries no bytes for can never be present.
                present = !marker.nil? && !wanted_files[marker].nil? &&
                          Array(installed[event]).any? do |group|
                            ours?(group, mode) &&
                              Array(group['hooks']).any? do |h|
                                path = config_path(h['command'])
                                !path.nil? &&
                                  h['command'].to_s == expected_command(entry['argv'], path) &&
                                  config_bytes(path) == wanted_files[marker]
                              end
                          end
                missing << { event: event, config: marker } unless present
              end
            end

            # Byte equality is strict on purpose — plan_for decides
            # config_changed with the same comparison, and relaxing one side
            # alone re-opens the validate-versus-projector disagreement that
            # round 8 closed. But the strictness is about the equality, not
            # the label: a missing entry whose declared basename is carried by
            # a live owned command over a still-readable file is not absent.
            # That gate is installed and firing — after a trailing newline
            # from an editor's save, an operator's hand edit, or an upgrade
            # past a compiler that emits different bytes — and answering
            # `not_installed` with a remedy saying to install was the round 8
            # defect this partition removes. Since round 9 tightened `present`
            # to the whole command, a declared config run by the wrong command
            # arrives here too: live and readable, so it reports as diverged,
            # and re-applying restores the declared command the same way it
            # restores declared bytes.
            diverged, missing = missing.partition do |m|
              Array(installed[m[:event]]).any? do |group|
                ours?(group, mode) && Array(group['hooks']).any? do |h|
                  path = config_path(h['command'])
                  !path.nil? && File.basename(path) == m[:config] && !config_bytes(path).nil?
                end
              end
            end

            # The other direction: entries this mode owns that realize no
            # declared hook. Exclusive with `missing` and `diverged`, by
            # operator ruling 甲 (2026-08-14) — reversing round 8, whose
            # filter admitted every byte-unequal owned entry, so a live,
            # currently-declared gate appeared under `stale` while the same
            # config was reported `diverged`, and a vanished declared config
            # was reported twice, once as its missing declaration and once as
            # its dead command. The stale_installed branch's own detail —
            # "hooks this mode no longer declares" — was false of both. Each
            # defect now reports exactly once: a declared config that fails
            # its equality is `missing` or `diverged`, and `stale` keeps only
            # what nothing else reports — an undeclared basename (a withdrawn
            # gate), a command naming no config, or a surplus owned copy
            # beside a valid realization of the same config, which is a hook
            # the declaration does not ask for. Verdict order is unaffected:
            # not_installed and diverged both outrank stale_installed.
            reported = (missing + diverged).map { |m| m[:config] }
            stale = installed.flat_map do |event, groups|
              Array(groups).select { |g| ours?(g, mode) }.flat_map do |group|
                Array(group['hooks']).filter_map do |h|
                  cmd = h['command'].to_s
                  path = config_path(cmd)
                  base = path && File.basename(path)
                  next if base && reported.include?(base)

                  declared = base && wanted_files[base]
                  next if !declared.nil? && cmd == expected_command(wanted_argv[base], path) &&
                          config_bytes(path) == declared

                  { event: event, command: cmd }
                end
              end
            end

            if !missing.empty?
              { status: 'not_installed', missing: missing, diverged: diverged, stale: stale,
                remedy: 'run the mode_hooks_project tool to install; it reports the ' \
                        'diff and asks before writing' }
            elsif !diverged.empty?
              { status: 'diverged', diverged: diverged, stale: stale,
                detail: 'a declared gate is installed and live, and what runs no longer ' \
                        'matches what the declaration compiles to — its config bytes ' \
                        'or its command',
                remedy: 'run the mode_hooks_project tool to re-apply; it restores the ' \
                        'declared bytes, reports the diff and asks before writing' }
            elsif !stale.empty?
              { status: 'stale_installed', stale: stale,
                detail: 'the harness still runs hooks this mode no longer declares',
                remedy: 'run the mode_hooks_project tool to remove them; it reports the ' \
                        'diff and asks before writing' }
            else
              { status: wanted.empty? ? 'nothing_declared' : 'ok',
                detail: wanted.empty? ? 'declaration installs no hooks, and none is installed' :
                        'every declared hook is present in the harness config' }
            end
          end

          # --- helpers ------------------------------------------------------

          def verdict(checks)
            return 'DRIFT' if checks[:drift][:status] == 'drift'
            return 'REFUSED' if checks[:resolvable][:status] == 'refused'
            return 'NOT_INSTALLED' if checks[:installed][:status] == 'not_installed'
            # A declared gate that is installed and live but whose config no
            # longer carries the compiled bytes is not absence. Round 8
            # labeled it `not_installed` and told the operator to install —
            # about a blocking gate that was already firing on every turn.
            return 'DIVERGED' if checks[:installed][:status] == 'diverged'
            # A live gate the declaration has withdrawn is a divergence between
            # the mode and the harness, the same as a missing one, and it is the
            # more dangerous direction: the withdrawn gate is still blocking.
            return 'STALE_INSTALLED' if checks[:installed][:status] == 'stale_installed'
            # Unanswered is not OK. The installed check answers 'unknown' when
            # there is no .claude/settings.json to read — which is what a fresh
            # project looks like, since Claude Code writes settings.local.json
            # for permissions — and the fall-through here told exactly that
            # consumer, on their first validate, that everything was fine
            # before anything had been installed.
            return 'UNKNOWN_INSTALLED' if checks[:installed][:status] == 'unknown'
            return 'OPEN_QUESTIONS' if checks[:declared][:status] == 'open'

            'OK'
          end

          # Sections whose prose carries a checkable limit, minus those already
          # gated and those the author explicitly declined.
          def candidates(body, gated, declined)
            settled = (gated + declined).map { |s| normalize(s) }
            sections(body).select do |heading, text|
              LIMIT_HINT.match?(text) && !settled.include?(normalize(heading))
            end.map(&:first)
          end

          def sections(body)
            out = []
            current = nil
            buffer = []
            body.each_line do |line|
              if line =~ /^#{'#'}{2,4}\s+(.+?)\s*$/
                out << [current, buffer.join] if current
                current = Regexp.last_match(1)
                buffer = []
              elsif current
                buffer << line
              end
            end
            out << [current, buffer.join] if current
            out
          end

          def normalize(str)
            str.to_s.gsub(/[[:space:]§]/, '').downcase
          end

          def gated_sections(document)
            (document['hooks'] || {}).values.flatten.map { |e| e['section'] }.compact.uniq
          end

          def declared_version(body)
            body[/^\*\*Version:\*\*\s*(\S+)/i, 1]
          end

          def compile(mode, document, body)
            return nil if document.nil?

            ModeHooksCompiler.new.compile(mode_name: mode, document: document, mode_body: body)
          end

          def document_path(mode, body_path = nil)
            ModeHooksLocator.find(mode, skillset_root: SKILLSET_ROOT,
                                        mode_body_path: body_path)
          end

          def load_document(path)
            ModeHooksLocator.load(path)
          end

          def active_mode
            return nil unless defined?(::KairosMcp::SkillsConfig)

            ::KairosMcp::SkillsConfig.load['instructions_mode']
          rescue StandardError
            nil
          end

          def mode_body_path(mode)
            return nil unless defined?(::KairosMcp)

            case mode
            when 'developer' then ::KairosMcp.md_path
            when 'user'      then ::KairosMcp.quickguide_path
            when 'tutorial'  then ::KairosMcp.tutorial_path
            else File.join(::KairosMcp.skills_dir, "#{mode}.md")
            end
          rescue StandardError
            nil
          end

          def resolve_project_root
            if defined?(::KairosMcp) && ::KairosMcp.respond_to?(:project_root)
              ::KairosMcp.project_root
            else
              Dir.pwd
            end
          end

          def watch_paths(project_root)
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
        end
      end
    end
  end
end
