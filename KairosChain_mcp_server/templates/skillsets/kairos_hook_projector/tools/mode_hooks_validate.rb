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

            text_content(JSON.pretty_generate(body))
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

            body = File.read(body_path)
            doc_path = document_path(mode, body_path)
            document = doc_path ? load_document(doc_path) : nil

            checks = {}
            checks[:declared] = check_declared(document, doc_path, body)
            checks[:drift] = check_drift(document, body, body_path)
            compiled = compile(mode, document, body)
            checks[:resolvable] = check_resolvable(compiled)
            checks[:installed] = check_installed(compiled, project_root)

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

          # What the declaration compiles to vs what the harness actually runs.
          def check_installed(compiled, project_root)
            settings_path = File.join(project_root.to_s, '.claude', 'settings.json')
            unless File.exist?(settings_path)
              return { status: 'unknown', detail: 'no .claude/settings.json' }
            end

            installed = JSON.parse(File.read(settings_path))['hooks'] || {}
            wanted = compiled&.compiled? ? compiled.artifact['hooks'] : {}

            missing = []
            wanted.each do |event, entries|
              entries.each do |entry|
                script = entry['command'].to_s[%r{[^/\s]+\.py}]
                present = Array(installed[event]).any? do |group|
                  Array(group['hooks']).any? { |h| h['command'].to_s.include?(script.to_s) }
                end
                missing << { event: event, command: entry['command'] } unless present
              end
            end

            if missing.empty?
              { status: wanted.empty? ? 'nothing_declared' : 'ok',
                detail: wanted.empty? ? 'declaration installs no hooks' :
                        'every declared hook is present in the harness config' }
            else
              { status: 'not_installed', missing: missing,
                remedy: 'run `kairos-chain mode project` to install; it reports the ' \
                        'diff and asks before writing' }
            end
          end

          # --- helpers ------------------------------------------------------

          def verdict(checks)
            return 'DRIFT' if checks[:drift][:status] == 'drift'
            return 'REFUSED' if checks[:resolvable][:status] == 'refused'
            return 'NOT_INSTALLED' if checks[:installed][:status] == 'not_installed'
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
              File.join(project_root.to_s, '.claude', 'settings.json'),
              File.join(SKILLSET_ROOT, 'plugin', 'hooks.json')
            ]
          end
        end
      end
    end
  end
end
