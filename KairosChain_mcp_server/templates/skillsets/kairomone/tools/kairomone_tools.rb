# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module KairomoneSkillSet
      module Tools
        class Base < KairosMcp::Tools::BaseTool
          def category; :knowledge; end
          def usecase_tags; %w[kairomone basic local]; end

          private

          def instance(restored_id: nil)
            # Free tier v0 is single-owner local use. Never place authenticated
            # users from a multiuser server in one shared profile or store.
            if @safety && @safety.respond_to?(:current_user) && @safety.current_user
              raise ::Kairomone::Error, 'Kairomone basic v0 supports a dedicated local single-owner KC instance; authenticated multiuser hosting is unsupported'
            end
            ::Kairomone::Instance.new(restored_id: restored_id)
          end

          def output
            text_content(JSON.pretty_generate(yield))
          rescue StandardError => e
            text_content(JSON.pretty_generate(success: false, error: e.message))
          end
        end

        class Init < Base
          def name; 'kairomone_init'; end
          def description; 'Initialize one persistent Kairomone basic profile for this dot. Repeats preserve the existing profile; host L0 and instruction mode are unchanged.'; end
          def input_schema
            { type: 'object', properties: { dot_id: { type: 'string' }, display_name: { type: 'string' } }, required: %w[dot_id display_name], additionalProperties: false }
          end
          def call(args)
            output { instance.init(dot_id: args['dot_id'], display_name: args['display_name']) }
          end
        end

        class Status < Base
          def name; 'kairomone_status'; end
          def description; 'Read profile, deterministic levels, explicit profession, bounded worker state, canonical L1/L2 counts and locally verified dedicated chain status; optionally generate an offline HTML snapshot at the fixed exports/status.html path.'; end
          def input_schema
            { type: 'object', properties: { render_html: { type: 'boolean' }, instance: { type: 'string', description: 'Optional restored target ID; read-only inspection' } }, additionalProperties: false }
          end
          def call(args)
            output { instance(restored_id: args['instance']).status(render_html: args['render_html'] == true) }
          end
        end

        class Observe < Base
          def name; 'kairomone_observe'; end
          def description; 'Explicitly save a bounded L2 observation using ContextManager. No autonomous learning or L1 promotion; 16 KiB content maximum.'; end
          def input_schema
            { type: 'object', properties: { title: { type: 'string' }, content: { type: 'string' } }, required: %w[title content], additionalProperties: false }
          end
          def call(args)
            output { instance.observe(title: args['title'], content: args['content']) }
          end
        end

        class Knowledge < Base
          def name; 'kairomone_knowledge'; end
          def description; 'Create, get or list dedicated canonical Kairomone L1 knowledge. Create only on explicit user instruction; never overwrite an existing ID. Success requires a verified matching canonical ledger hash. This dedicated store is not searched by host knowledge_get.'; end
          def input_schema
            { type: 'object', properties: { command: { type: 'string', enum: %w[create get list] },
              id: { type: 'string' }, title: { type: 'string' }, content: { type: 'string' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              store = instance
              case args['command']
              when 'create' then store.create_knowledge(id: args['id'], title: args['title'], content: args['content'])
              when 'get' then store.read_knowledge(id: args['id'])
              when 'list' then store.list_knowledge
              else raise ::Kairomone::Error, 'Expected create, get or list'
              end
            end
          end
        end

        class Profession < Base
          def name; 'kairomone_profession'; end
          def description; 'List profession unlocks or explicitly select an unlocked profession. Selection persists outside the SkillSet and biases learning topics only; permissions, budgets and L0 stay unchanged.'; end
          def input_schema
            { type: 'object', properties: { command: { type: 'string', enum: %w[list select] }, id: { type: 'string' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              case args['command']
              when 'list' then { success: true, profession: instance.profession_status }
              when 'select' then instance.select_profession(id: args['id'])
              else raise ::Kairomone::Error, 'Expected list or select'
              end
            end
          end
        end

        class Companion < Base
          def name; 'kairomone_companion'; end
          def description; 'Read or explicitly configure this owned companion; retrieve bounded context or ingest a reviewed summary only with current global and conversation consent. No model invocation, L0 change, XP award or automatic L1 promotion.'; end
          def input_schema
            { type: 'object', properties: { command: { type: 'string', enum: %w[status configure context remember recover revoke] },
              arguments: { type: 'object' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              methods = { 'status' => :companion_status, 'configure' => :configure_companion, 'context' => :companion_context, 'remember' => :remember_companion, 'recover' => :recover_companion_memory, 'revoke' => :revoke_companion_memory }
              method = methods[args['command']]
              raise ::Kairomone::Error, 'Invalid companion command' unless method
              input = args.fetch('arguments', {})
              raise ::Kairomone::Error, 'Arguments must be an object' unless input.is_a?(Hash)
              store = instance
              allowed = store.method(method).parameters.map { |_kind, key| key.to_s }
              raise ::Kairomone::Error, 'Unexpected companion input fields' unless (input.keys - allowed).empty?
              store.public_send(method, **input.transform_keys(&:to_sym))
            end
          end
        end

        class Growth < Base
          def name; 'kairomone_growth'; end
          def description; 'Bounded, explicitly authorized growth protocol. No scheduler or web research is built in. Workers must provide actual retrieved evidence. Claim consumes one of at most 10 lifetime attempts; retries never reset budget. Status distinguishes recent worker heartbeat from always-on service.'; end
          def input_schema
            { type: 'object', properties: {
              command: { type: 'string', enum: %w[status configure request claim heartbeat commit fail stop] },
              request_id: { type: 'string' }, topic: { type: 'string' }, max_cycles: { type: 'integer', minimum: 1, maximum: 10 },
              already_used: { type: 'integer', minimum: 0, maximum: 10 }, resume: { type: 'boolean' },
              profession_id: { type: 'string' }, bias_applied: { type: 'boolean' }, worker_id: { type: 'string' },
              lease_seconds: { type: 'integer', minimum: 1, maximum: 900 }, claim_token: { type: 'string' },
              evidence: { type: 'object', description: 'Strict evidence: knowledge {title,content}, finding, uncertainty, counterexample, sources [{url,title,retrieved_at,excerpt,retrieval_reference,excerpt_sha256}]' }, reason: { type: 'string' }
            }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              growth = instance.autonomy
              case args['command']
              when 'status' then growth.status
              when 'configure' then growth.configure(max_cycles: args.fetch('max_cycles', 10), already_used: args.fetch('already_used', 0))
              when 'request' then growth.request(request_id: args['request_id'], topic: args['topic'], max_cycles: args.fetch('max_cycles', 10), already_used: args.fetch('already_used', 0), resume: args.fetch('resume', false), profession_id: args.fetch('profession_id', 'generalist'), bias_applied: args.fetch('bias_applied', false))
              when 'claim' then growth.claim(worker_id: args['worker_id'], lease_seconds: args.fetch('lease_seconds', 300))
              when 'heartbeat' then growth.heartbeat(claim_token: args['claim_token'])
              when 'commit' then growth.commit(claim_token: args['claim_token'], evidence: args['evidence'])
              when 'fail' then growth.fail(claim_token: args['claim_token'], reason: args['reason'])
              when 'stop' then growth.stop(reason: args.fetch('reason', 'Explicit stop'))
              else raise ::Kairomone::Error, 'Unknown growth command'
              end
            end
          end
        end

        class Backup < Base
          def name; 'kairomone_backup'; end
          def description; 'Create/verify a bounded owned-instance backup or restore to a NEW read-only recovery target. restore_new resumes operation only when the active directory is wholly absent. Includes owned profile, profession, bounded growth history/budget, L1/L2 and dedicated ledger; restored growth is stopped; does not collect external credential stores. User-authored text may contain secrets. SHA-256 detects inconsistency but is not authentication or encryption.'; end
          def input_schema
            { type: 'object', properties: { command: { type: 'string', enum: %w[create verify restore restore_new] }, file: { type: 'string', description: 'Backup basename: owned backups directory, or fixed host kairomone-inbox for restore_new' }, dot_id: { type: 'string', description: 'Expected original dot ID for restore_new into a wholly absent active instance' }, target_id: { type: 'string', description: 'New target under the host kairomone-restored directory' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              store = instance
              case args['command']
              when 'create' then store.create_backup
              when 'verify' then store.verify_backup(file: args['file'])
              when 'restore' then store.restore_backup(file: args['file'], target_id: args['target_id'])
              when 'restore_new' then store.restore_new(file: args['file'], dot_id: args['dot_id'])
              else raise ::Kairomone::Error, 'Expected create, verify, restore or restore_new'
              end
            end
          end
        end
      end
    end
  end
end
