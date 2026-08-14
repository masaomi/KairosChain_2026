# frozen_string_literal: true

require 'json'
require 'digest'
require_relative '../lib/boot_time_assertion'
require_relative '../lib/mode_hooks_compiler'
require_relative '../lib/mode_hooks_locator'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      module Tools
        # Declare a gate for a mode without hand-editing JSON.
        #
        #   mode_hooks_add(mode: <name>, gate: <kind>)
        #     -> writes/updates <mode>.mode_hooks.json beside the mode body
        #     -> names the exact next command (mode_hooks_project)
        #     -> NEVER touches .claude/settings.json
        #
        # This tool stops at the declaration, by operator ruling 甲
        # (2026-08-14). It does not propose, does not apply, and does not
        # write the harness config: collapsing propose -> confirm -> apply
        # into one call would make this tool compute and echo back its own
        # confirmation hash, which turns that gate into a formality. The
        # install stays two mode_hooks_project calls away, and the result
        # names the first of them.
        #
        # Why this tool may write without a confirmation echo when the
        # projector may not: it is append-only. Creating a file that does not
        # exist and adding an entry that does not exist are both
        # non-destructive — no tuned threshold, no author note, no binding,
        # and no other entry is ever modified or removed, and an entry with
        # the same gate already on the event is refused rather than
        # overwritten. The projector's confirmation protects a destructive
        # write (it rewrites and can remove its own entries); here there is
        # nothing for a confirmation to protect. "Append-only" is a claim
        # about content, not bytes: an append re-serializes the document, so
        # incidental formatting normalizes while every key and entry the
        # author wrote — underscore-prefixed notes included — survives.
        #
        # The catalogue of gate kinds is mode_hooks/_EXAMPLE.json and nothing
        # else. That file already carries, per kind: the event it binds to
        # (the key the entry sits under), section, blocking, and the full
        # params. A second file carrying the same numbers would drift — this
        # project has been bitten by exactly that — so adding a future kind
        # is "add an entry to _EXAMPLE.json under its event" plus shipping
        # the gate itself, and no edit here.
        class ModeHooksAdd < ::KairosMcp::Tools::BaseTool
          SKILLSET_ROOT = File.expand_path('..', __dir__)
          SKILLSET_NAME = 'kairos_hook_projector'

          def name
            'mode_hooks_add'
          end

          def description
            "Declare a gate for an instruction mode without hand-editing JSON: " \
              'copy the catalogue entry for the requested gate kind from ' \
              'mode_hooks/_EXAMPLE.json into <mode>.mode_hooks.json beside the ' \
              'mode body — creating the declaration, or appending to it; never ' \
              'overwriting an entry already on the event — then name the ' \
              'mode_hooks_project call that installs it. Never touches ' \
              '.claude/settings.json. Called without gate, lists the catalogue ' \
              'of kinds and writes nothing.'
          end

          def category
            :meta
          end

          def usecase_tags
            %w[hooks declaration gate catalogue instruction-mode]
          end

          def related_tools
            %w[mode_hooks_validate mode_hooks_project hooks_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                mode: {
                  type: 'string',
                  description: 'Instruction mode name. Defaults to the active mode ' \
                               'from instructions_mode in the skills config.'
                },
                gate: {
                  type: 'string',
                  description: 'Gate kind to declare, e.g. "readable_gate". ' \
                               'Omitted: list the catalogue of kinds and write nothing.'
                }
              },
              additionalProperties: false
            }
          end

          def call(arguments)
            project_root = resolve_project_root
            watch = watch_paths(project_root)

            # This tool writes, so the assertion cannot cover its actual
            # target — it covers the one path the ruling forbids: the harness
            # config. Any write to it, by this tool or anything it calls,
            # raises instead of returning success; and as in the validator,
            # the verification is reported, not merely performed, so a
            # deleted verify_post! shows in the result.
            assertion = BootTimeAssertion.new(watch_paths: watch)
            assertion.snapshot_pre!
            body = run(arguments || {})
            assertion.verify_post!

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

          def run(args)
            return catalogue_listing if args['gate'].nil?

            mode = args['mode'] || active_mode
            return { error: 'no_active_mode' } if mode.nil? || mode == 'none'

            # The locator never resolves a leading-underscore name — that
            # marks the shipped schemas and the example, not a mode — so a
            # declaration written for one could never be read back by any
            # tool here. Refuse rather than write an orphan.
            if mode.to_s.start_with?('_')
              return { mode: mode, error: 'mode_not_locatable', nothing_written: true,
                       detail: 'a leading underscore marks a non-mode file in ' \
                               'mode_hooks/; the locator never resolves it' }
            end

            body_path = mode_body_path(mode)
            unless body_path && File.exist?(body_path)
              return { mode: mode, error: 'mode_body_not_found', looked_at: body_path }
            end

            body = File.read(body_path, encoding: 'UTF-8')
            found = catalogue_entry(args['gate'])
            if found.nil?
              return { mode: mode, gate: args['gate'], error: 'gate_not_in_catalogue',
                       available: catalogue_gates, source: catalogue_path,
                       nothing_written: true }
            end

            doc_path = ModeHooksLocator.find(mode, skillset_root: skillset_root,
                                                   mode_body_path: body_path)
            if doc_path.nil?
              create(mode, body_path, body, found)
            else
              append(mode, body_path, body, doc_path, found)
            end
          end

          # --- the catalogue -------------------------------------------------

          def catalogue_path
            File.join(skillset_root, 'mode_hooks', '_EXAMPLE.json')
          end

          def load_catalogue
            JSON.parse(File.read(catalogue_path, encoding: 'UTF-8'))
          end

          def catalogue_listing
            {
              action: 'catalogue',
              source: catalogue_path,
              gates: catalogue_gates,
              nothing_written: true,
              note: 'call again with gate=<kind> to write a declaration for a mode'
            }
          end

          def catalogue_gates
            (load_catalogue['hooks'] || {}).flat_map do |event, entries|
              Array(entries).filter_map do |entry|
                next nil unless entry.is_a?(Hash) && entry['gate']

                gate = { gate: entry['gate'], event: event }
                desc = one_line_description(entry)
                desc ? gate.merge(description: desc) : gate
              end
            end
          end

          # @return [Hash, nil] { event:, entry: } with annotations stripped
          def catalogue_entry(kind)
            (load_catalogue['hooks'] || {}).each do |event, entries|
              Array(entries).each do |entry|
                next unless entry.is_a?(Hash) && entry['gate'] == kind

                return { event: event, entry: strip_annotations(entry) }
              end
            end
            nil
          end

          # An optional one-line description a catalogue entry may carry in a
          # `_description` annotation (string, or array whose first element is
          # the line). The shipped example carries none today; the mechanism
          # is here so a future kind can describe itself without the tool
          # changing.
          def one_line_description(entry)
            desc = entry['_description']
            desc = desc.first if desc.is_a?(Array)
            desc.is_a?(String) ? desc.lines.first&.strip : nil
          end

          # Underscore-prefixed keys are the example's author notes. They must
          # not be copied into a mode's declaration: the ones inside `params`
          # would even reach the compiled gate config verbatim, since params
          # are the mode's own and pass through untouched.
          def strip_annotations(obj)
            case obj
            when Hash
              obj.reject { |k, _| k.to_s.start_with?('_') }
                 .transform_values { |v| strip_annotations(v) }
            when Array then obj.map { |v| strip_annotations(v) }
            else obj
            end
          end

          # --- create / append -----------------------------------------------

          def create(mode, body_path, body, found)
            # The locator's own first candidate: <mode>.mode_hooks.json beside
            # the mode body — the preferred location its comment names.
            target = ModeHooksLocator.candidates(mode, skillset_root, body_path).first
            binding = {}
            version = declared_version(body)
            binding['mode_version'] = version if version
            binding['mode_body_sha256'] = Digest::SHA256.hexdigest(body)
            document = {
              'mode_name' => mode,
              'version' => '1',
              'binding' => binding,
              'hooks' => { found[:event] => [found[:entry]] }
            }
            deliver(mode, 'created', target, document, body, found)
          end

          def append(mode, body_path, body, doc_path, found)
            # Only the beside-the-body location is writable. A declaration the
            # locator found inside the SkillSet is distributed with it: a write
            # there would be undone by the next system_upgrade, and this tool's
            # ruling authorizes exactly one target — the file beside the body.
            unless File.dirname(doc_path) == File.dirname(body_path)
              return { mode: mode, error: 'declaration_ships_inside_the_skillset',
                       declaration: doc_path, nothing_written: true,
                       note: 'copy it beside the mode body as ' \
                             "#{mode}.mode_hooks.json first, then re-run" }
            end

            unless doc_path.end_with?('.json')
              return { mode: mode, error: 'declaration_not_json',
                       declaration: doc_path, nothing_written: true,
                       note: 'this declaration is YAML; appending would rewrite the ' \
                             'whole file in a different format. Add the entry by ' \
                             'hand, or convert the file to JSON first.' }
            end

            begin
              document = ModeHooksLocator.load(doc_path)
            rescue JSON::ParserError => e
              return { mode: mode, error: 'declaration_unreadable', declaration: doc_path,
                       detail: e.message, nothing_written: true }
            end
            unless document.is_a?(Hash)
              return { mode: mode, error: 'declaration_unreadable', declaration: doc_path,
                       detail: "top level is #{document.class}, not an object",
                       nothing_written: true }
            end

            declared = document['mode_name']
            unless declared == mode
              return { mode: mode, error: 'mode_name_mismatch', declaration: doc_path,
                       declared: declared, requested: mode, nothing_written: true,
                       note: 'the declaration names a different mode than the one it ' \
                             'would be compiled as; nothing was appended' }
            end

            # The declaration as it stands must compile before anything is
            # added to it. This is also where a drifted binding refuses: the
            # binding hash is the author's record of which body they read, and
            # silently refreshing it here would erase the drift signal
            # mode_hooks_validate exists to raise. So it is never recomputed —
            # the drift is reported and the author revisits the declaration.
            existing = ModeHooksCompiler.new.compile(mode_name: mode, document: document,
                                                     mode_body: body)
            if existing.refused?
              return { mode: mode, error: 'existing_declaration_refused',
                       declaration: doc_path, refusal: existing.record['refusal'],
                       nothing_written: true,
                       note: 'the declaration on disk does not compile as it stands; ' \
                             'repair it first — mode_hooks_validate reports what it needs' }
            end

            # The append-only refusal. An entry with the same gate on the same
            # event carries thresholds the author may have tuned; overwriting
            # them is exactly the destructive write this tool is not allowed
            # to make without a confirmation gate it deliberately lacks.
            event = found[:event]
            duplicate = Array(document.dig('hooks', event)).any? do |entry|
              entry.is_a?(Hash) && entry['gate'] == found[:entry]['gate']
            end
            if duplicate
              return { mode: mode, gate: found[:entry]['gate'], event: event,
                       error: 'gate_already_declared', declaration: doc_path,
                       nothing_written: true,
                       note: 'append-only: an entry with this gate already sits on ' \
                             'this event, and its thresholds may be tuned. Edit the ' \
                             'declaration by hand to change it.' }
            end

            document['hooks'] ||= {}
            document['hooks'][event] ||= []
            document['hooks'][event] << found[:entry]
            deliver(mode, 'appended', doc_path, document, body, found,
                    binding_untouched: true)
          end

          # Compile gate, then the one write site — strictly in that order.
          # Every refusal the compiler can raise — an unsafe mode identity, an
          # unknown gate, a schema violation, a drifted binding — leaves the
          # disk exactly as it was: whatever this tool writes compiles, or it
          # is not written.
          def deliver(mode, action, target, document, body, found, extra = {})
            compiled = ModeHooksCompiler.new.compile(mode_name: mode, document: document,
                                                     mode_body: body)
            if compiled.refused?
              return { mode: mode, action: 'refused',
                       refusal: compiled.record['refusal'], nothing_written: true,
                       note: "the #{action == 'created' ? 'new declaration' : 'appended result'} " \
                             'does not compile, so it was not written' }
            end

            write_declaration(target, document)
            result = {
              mode: mode,
              action: action,
              declaration: target,
              added: { 'event' => found[:event] }.merge(found[:entry]),
              compiled: { hook_count: compiled.record.dig('output', 'hook_count'),
                          events: compiled.record.dig('output', 'events') },
              next_command: %(mode_hooks_project mode="#{mode}"),
              note: 'the declaration is written and nothing is installed yet: ' \
                    'mode_hooks_project proposes the install and writes nothing ' \
                    'until its confirm_sha256 is echoed back. The thresholds are ' \
                    "the catalogue's starting numbers and are the mode's own — " \
                    'tune them in the written file. .claude/settings.json was ' \
                    'not touched.'
            }.merge(extra)
            result[:binding] = document['binding'] if action == 'created'
            result
          end

          def write_declaration(path, document)
            # The body was just read from this directory, so it exists; no
            # mkdir, so a refused or crashed call has created nothing.
            tmp = "#{path}.tmp.#{Process.pid}.#{object_id}"
            File.write(tmp, JSON.pretty_generate(document) + "\n", encoding: 'UTF-8')
            File.rename(tmp, path)
          end

          # --- environment ---------------------------------------------------

          def skillset_root
            SKILLSET_ROOT
          end

          def declared_version(body)
            body[/^\*\*Version:\*\*\s*(\S+)/i, 1]
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
              # The path operator ruling 甲 forbids this tool to touch. The
              # declaration it writes lives beside the mode body and is not
              # watched — it is the tool's declared write target.
              File.join(project_root.to_s, '.claude', 'settings.json')
            ]
          end
        end
      end
    end
  end
end
