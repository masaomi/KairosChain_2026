# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative 'mode_hooks_schema'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      # Stage 1 compile path: (mode identity, mode_hooks document) -> (artifact, record).
      #
      # Design reference: docs/drafts/kairos_hook_projector_stage1_design_v0.2_draft.md
      #
      # What this deliberately does NOT do:
      #   - persist anything (Inv-8). Both outputs are return values.
      #   - touch .claude/settings.json (Inv-1). That surface belongs to Stage 2.
      #   - resolve composition (Inv-3). `extends` / `conflict_policy` with
      #     semantic content is refused, not ignored.
      #   - decide whether a section deserves a gate. That is an authorial act;
      #     the compiler only refuses to compile what it cannot resolve.
      #
      # The artifact is a pure function of (mode identity, document): filesystem
      # locations appear as substitution tokens, not resolved paths, so the same
      # input yields a byte-identical artifact on any machine (Inv-2).
      class ModeHooksCompiler
        RECORD_VERSION = '1'
        ARTIFACT_VERSION = '1'

        # Substitution token. Stage 2 resolves it when it writes.
        CONFIG_ROOT = '${KAIROS_HOOK_CONFIG_ROOT}'

        # Gate implementations the core ships, named by the executable the
        # harness invokes. The executable — not an interpreter plus a script
        # path — is what goes in the artifact: PluginProjector projects a
        # `kairos-`-prefixed command without warning, the shim discovers its own
        # interpreter so no instance is pinned to /usr/bin/python3, and the
        # gate's location stays out of the artifact, which must remain a pure
        # function of (mode identity, declaration).
        KNOWN_GATES = {
          'readable_gate' => { command: 'kairos-readable-gate', timeout: 10 }
        }.freeze

        # Only Stop-family payloads carry `stop_hook_active`, which is the gate's
        # only once-per-turn brake. A gate attached to any other event would
        # block on every invocation with nothing able to clear it.
        GATE_EVENTS = %w[Stop SubagentStop].freeze

        # Stands in the record's identity field when the supplied mode name is
        # not usable as one. Deliberately not a valid mode name itself.
        UNUSABLE_MODE_NAME = '(unsafe mode identity)'

        COMPOSITION_FIELDS = %w[extends conflict_policy].freeze

        Result = Struct.new(:artifact, :record, keyword_init: true) do
          def compiled?
            record['outcome'] == 'compiled'
          end

          def refused?
            !compiled?
          end
        end

        # @param mode_name [String] external mode identity
        # @param document [Hash, nil] parsed mode_hooks document; nil = absent
        # @param mode_body [String, nil] current mode body, for drift detection
        def compile(mode_name:, document: nil, mode_body: nil)
          unless safe_mode_name?(mode_name)
            # The record's mode_name is an identity, and the schema requires a
            # usable one. An unusable identity is recorded as unusable, with the
            # value that was attempted carried in the detail, where it is a
            # string rather than a name. Recording the raw value in the identity
            # field made the refusal record fail its own schema — caught by the
            # producer-side validation, not by a reviewer.
            return refusal(UNUSABLE_MODE_NAME, nil, nil, 'unsafe_mode_name',
                           "mode identity #{mode_name.inspect} is not a single safe path " \
                           'segment; it reaches a filename and must not route')
          end
          return empty_result(mode_name, 'absent', nil) if document.nil?

          doc_sha = sha256(canonical_json(document))

          # Shape first. Every malformed-input class below this line — a
          # document that is not an object, `hooks` that is not a map of
          # arrays, an entry missing `section` — is a schema failure, and a
          # schema failure is a refusal. Reaching those shapes without this
          # check raised raw Ruby exceptions, which is the third domain outcome
          # Inv-C1 forbids.
          shape = ModeHooksSchema.validate(document, document_schema)
          unless shape.valid?
            return refusal(mode_name, doc_sha, nil, 'schema_invalid', shape.message)
          end

          if (bad = composition_content(document))
            return refusal(mode_name, doc_sha, document, 'composition_content_present',
                           "#{bad} carries semantic content; composition is Stage 4")
          end

          if (event = unsupported_event(document))
            return refusal(mode_name, doc_sha, document, 'unsupported_event',
                           "event #{event.inspect} carries no once-per-turn brake; " \
                           "gates attach to #{GATE_EVENTS.join(' or ')}")
          end

          declared = document['mode_name']
          if declared != mode_name
            return refusal(mode_name, doc_sha, document, 'binding_mismatch',
                           "document declares mode_name #{declared.inspect}, " \
                           "compiled as #{mode_name.inspect}")
          end

          if (drift = binding_drift(document, mode_body))
            return refusal(mode_name, doc_sha, document, 'binding_mismatch', drift)
          end

          entries = flatten_hooks(document['hooks'])
          if (unknown = entries.find { |e| !KNOWN_GATES.key?(e[:gate]) })
            return refusal(mode_name, doc_sha, document, 'unknown_gate',
                           "gate #{unknown[:gate].inspect} is not shipped by this core; " \
                           "known: #{KNOWN_GATES.keys.join(', ')}")
          end

          if entries.empty?
            return empty_result(mode_name, 'empty-document', doc_sha, document)
          end

          artifact = build_artifact(mode_name, document, entries)
          Result.new(
            artifact: artifact,
            record: record(mode_name, 'compiled', 'document', doc_sha, document,
                           output: output_summary(artifact, entries))
          )
        end

        # Canonicalization (Inv-D2). Sorted keys, no incidental whitespace, so
        # the empty artifact is byte-identical whichever mode produced it.
        def canonical_json(value)
          JSON.generate(deep_sort(value))
        end

        def empty_artifact
          { 'artifact_version' => ARTIFACT_VERSION, 'files' => {}, 'hooks' => {} }
        end

        private

        SCHEMA_DIR = File.expand_path('../mode_hooks', __dir__)

        def document_schema
          @document_schema ||= ModeHooksSchema.load_schema(File.join(SCHEMA_DIR, '_schema.json'))
        end

        def record_schema
          @record_schema ||= ModeHooksSchema.load_schema(File.join(SCHEMA_DIR, '_record_schema.json'))
        end

        # The mode identity becomes a filename. PathContainment is what the rest
        # of the core uses for exactly this; six other modules call it, including
        # the sibling projector. Reimplementing the check here would be the
        # drift it exists to prevent, so use it when it is loadable and apply the
        # same rule inline when this SkillSet runs outside the server.
        def safe_mode_name?(name)
          if defined?(::KairosMcp::PathContainment)
            ::KairosMcp::PathContainment.safe_segment?(name)
          else
            name.is_a?(String) && !name.empty? && !%w[. ..].include?(name) &&
              !name.include?(File::SEPARATOR) && !name.include?("\0") &&
              !name.start_with?(File::SEPARATOR)
          end
        end

        def unsupported_event(document)
          (document['hooks'] || {}).keys.find { |event| !GATE_EVENTS.include?(event) }
        end

        def deep_sort(value)
          case value
          when Hash then value.keys.sort.each_with_object({}) { |k, h| h[k] = deep_sort(value[k]) }
          when Array then value.map { |v| deep_sort(v) }
          else value
          end
        end

        def sha256(str)
          Digest::SHA256.hexdigest(str)
        end

        def composition_content(document)
          COMPOSITION_FIELDS.find do |field|
            v = document[field]
            v.is_a?(Array) ? !v.empty? : !(v.nil? || v.to_s.empty?)
          end
        end

        # Drift between the document's declared binding and the live mode body.
        # A document with no binding cannot drift-check; that is recorded, not
        # treated as a failure, because binding is optional by schema.
        def binding_drift(document, mode_body)
          binding = document['binding']
          return nil if binding.nil? || mode_body.nil?

          expected = binding['mode_body_sha256']
          return nil if expected.nil?

          actual = sha256(mode_body)
          return nil if actual == expected

          "mode body has changed since this document was authored " \
            "(declared #{expected[0, 12]}…, actual #{actual[0, 12]}…). " \
            'Revisit the declaration, then update binding.mode_body_sha256.'
        end

        # Declaration order within the document, positionally recorded. The rule
        # is deterministic and readable off the record alone (Inv-O1, Inv-O3).
        def flatten_hooks(hooks)
          return [] if hooks.nil? || hooks.empty?

          hooks.keys.sort.flat_map do |event|
            Array(hooks[event]).each_with_index.map do |entry, position|
              {
                event: event,
                position: position,
                gate: entry['gate'],
                section: entry['section'],
                params: entry['params'] || {},
                blocking: entry.key?('blocking') ? entry['blocking'] : true
              }
            end
          end
        end

        def build_artifact(mode_name, document, entries)
          files = {}
          hooks = Hash.new { |h, k| h[k] = [] }

          entries.each do |e|
            spec = KNOWN_GATES.fetch(e[:gate])
            # The event belongs in the name. Positions restart at zero per
            # event, so omitting it made two gates at the same position on
            # different events overwrite one another while both commands
            # pointed at whichever config survived.
            config_name = "#{mode_name}.#{e[:event]}.#{e[:gate]}.#{e[:position]}.json"
            files[config_name] = canonical_json(
              gate_config(mode_name, document, e)
            )
            hooks[e[:event]] << {
              'type' => 'command',
              'command' => [
                spec[:command],
                '--config',
                "#{CONFIG_ROOT}/#{config_name}"
              ].join(' '),
              'timeout' => spec[:timeout],
              'statusMessage' => "#{e[:gate]} (#{mode_name})"
            }
          end

          {
            'artifact_version' => ARTIFACT_VERSION,
            'files' => files,
            'hooks' => hooks.transform_values(&:itself)
          }
        end

        # The mode's numbers, verbatim, plus the identity a report needs. The
        # core adds no thresholds of its own here.
        def gate_config(mode_name, document, entry)
          entry[:params].merge(
            'mode_name' => mode_name,
            'mode_version' => document.dig('binding', 'mode_version'),
            'section' => entry[:section],
            'blocking' => entry[:blocking]
          )
        end

        def output_summary(artifact, entries)
          events = Hash.new { |h, k| h[k] = [] }
          entries.each do |e|
            events[e[:event]] << {
              'position' => e[:position],
              'gate' => e[:gate],
              'section' => e[:section],
              'blocking' => e[:blocking]
            }
          end
          {
            'artifact_sha256' => sha256(canonical_json(artifact)),
            'hook_count' => entries.size,
            'events' => events.transform_values(&:itself)
          }
        end

        def empty_result(mode_name, path, doc_sha, document = nil)
          artifact = empty_artifact
          Result.new(
            artifact: artifact,
            record: record(mode_name, 'compiled', path, doc_sha, document,
                           output: {
                             'artifact_sha256' => sha256(canonical_json(artifact)),
                             'hook_count' => 0,
                             'events' => {}
                           })
          )
        end

        def refusal(mode_name, doc_sha, document, category, detail)
          Result.new(
            artifact: nil,
            record: record(mode_name, 'refused', 'document', doc_sha, document,
                           refusal: { 'category' => category, 'detail' => detail })
          )
        end

        # Raised when the producer emits a record its own schema rejects. This
        # is a programmer fault, not a domain input, so it is not a refusal:
        # Inv-6 asks for a compile-time error and this is it. Letting such a
        # record through meant a schema-violating record reached the chain.
        class RecordSchemaDrift < StandardError; end

        def record(mode_name, outcome, path, doc_sha, document, output: nil, refusal: nil)
          built = build_record(mode_name, outcome, path, doc_sha, document,
                               output: output, refusal: refusal)
          result = ModeHooksSchema.validate(built, record_schema)
          unless result.valid?
            raise RecordSchemaDrift,
                  "compile record does not satisfy _record_schema.json: #{result.message}"
          end

          built
        end

        def build_record(mode_name, outcome, path, doc_sha, document, output: nil, refusal: nil)
          {
            'record_version' => RECORD_VERSION,
            'mode_name' => mode_name,
            'outcome' => outcome,
            'resolution_path' => path,
            'input' => {
              'document_sha256' => doc_sha,
              'binding' => document && document['binding']
            },
            'output' => output,
            'refusal' => refusal,
            'compiled_at' => Time.now.utc.iso8601
          }.compact
        end
      end
    end
  end
end
