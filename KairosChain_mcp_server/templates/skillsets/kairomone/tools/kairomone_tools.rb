# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module KairomoneSkillSet
      module Tools
        class Base < KairosMcp::Tools::BaseTool
          KAIROMONE = { type: 'string', description: 'Listing ID of the Kairomone this call is about (kairomone_list shows them). May be omitted while the host lists exactly one; with several, writes without it are refused and reads return the list.' }.freeze

          def category; :knowledge; end
          def usecase_tags; %w[kairomone basic local]; end

          private

          def single_owner!
            # Free tier is single-owner local use. Never place authenticated
            # users from a multiuser server in one shared profile or store.
            if @safety && @safety.respond_to?(:current_user) && @safety.current_user
              raise ::Kairomone::Error, 'Kairomone basic v0 supports a dedicated local single-owner KC instance; authenticated multiuser hosting is unsupported'
            end
          end

          # The individual a call addresses (design v0.6 M2). A write names it
          # when the host lists several; a read without a name returns the list.
          def instance(args = {}, read: false, restored_id: nil)
            single_owner!
            return ::Kairomone::Instance.new(restored_id: restored_id) if restored_id

            ::Kairomone::Instance.new(kairomone: args['kairomone'])
          rescue ::Kairomone::AmbiguousError => e
            raise e unless read

            throw :listing, { success: true, several: true, kairomones: ::Kairomone::Host.new.summaries,
                              note: 'Several Kairomones live on this host; name one with kairomone (writes always need it).' }
          end

          def output
            text_content(JSON.pretty_generate(catch(:listing) { yield }))
          rescue StandardError => e
            text_content(JSON.pretty_generate(success: false, error: e.message))
          end
        end

        class List < Base
          def name; 'kairomone_list'; end
          def description; 'List the Kairomones this host holds: listing ID, identity and name. Writes to a host with several must name one.'; end
          def input_schema
            { type: 'object', properties: {}, additionalProperties: false }
          end
          def call(_args)
            output do
              single_owner!
              { success: true, kairomones: ::Kairomone::Host.new.summaries }
            end
          end
        end

        class Init < Base
          def name; 'kairomone_init'; end
          def description; 'Make this host\'s one Kairomone (the one-individual shorthand of creation), or confirm the one already listed under that ID. Refused when other Kairomones live here. Host L0 and instruction mode are unchanged.'; end
          def input_schema
            { type: 'object', properties: { dot_id: { type: 'string', description: 'Identity and listing ID of the new Kairomone' }, display_name: { type: 'string' } }, required: %w[dot_id display_name], additionalProperties: false }
          end
          def call(args)
            output do
              single_owner!
              ::Kairomone::Instance.new(bind: false).init(dot_id: args['dot_id'], display_name: args['display_name'])
            end
          end
        end

        class Status < Base
          def name; 'kairomone_status'; end
          def description; 'Read a Kairomone\'s profile, level, profession, growth runs, canonical L1/L2 counts and locally verified ledger status; optionally generate an offline HTML snapshot at its fixed exports/status.html path. Without kairomone on a host with several, returns the list.'; end
          def input_schema
            { type: 'object', properties: { kairomone: KAIROMONE, render_html: { type: 'boolean' }, instance: { type: 'string', description: 'A listed Kairomone, or a 0.6 read-only recovery copy under kairomone-restored/, to inspect' } }, additionalProperties: false }
          end
          def call(args)
            output do
              raise ::Kairomone::Error, 'Give kairomone or instance, not both' if args['kairomone'] && args['instance']
              # instance: a listed Kairomone, or else a 0.6 read-only recovery copy.
              listed = args['instance'] && ::Kairomone::Host.new.listed?(args['instance'])
              target = listed ? instance(args.merge('kairomone' => args['instance']), read: true) : instance(args, read: true, restored_id: args['instance'])
              target.status(render_html: args['render_html'] == true)
            end
          end
        end

        class Observe < Base
          def name; 'kairomone_observe'; end
          def description; 'Explicitly save a bounded L2 observation for a Kairomone using ContextManager. No autonomous learning or L1 promotion; 16 KiB content maximum.'; end
          def input_schema
            { type: 'object', properties: { kairomone: KAIROMONE, title: { type: 'string' }, content: { type: 'string' } }, required: %w[title content], additionalProperties: false }
          end
          def call(args)
            output { instance(args).observe(title: args['title'], content: args['content']) }
          end
        end

        class Knowledge < Base
          def name; 'kairomone_knowledge'; end
          def description; 'Create, get or list a Kairomone\'s dedicated canonical L1 knowledge. Create only on explicit user instruction; never overwrite an existing ID. Success requires a verified matching canonical ledger hash. This dedicated store is not searched by host knowledge_get.'; end
          def input_schema
            { type: 'object', properties: { kairomone: KAIROMONE, command: { type: 'string', enum: %w[create get list] },
              id: { type: 'string' }, title: { type: 'string' }, content: { type: 'string' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              case args['command']
              when 'create' then instance(args).create_knowledge(id: args['id'], title: args['title'], content: args['content'])
              when 'get' then instance(args, read: true).read_knowledge(id: args['id'])
              when 'list' then instance(args, read: true).list_knowledge
              else raise ::Kairomone::Error, 'Expected create, get or list'
              end
            end
          end
        end

        class Profession < Base
          def name; 'kairomone_profession'; end
          def description; 'List profession unlocks or explicitly select an unlocked profession for a Kairomone. A profession biases learning topics only; permissions, limits and L0 stay unchanged.'; end
          def input_schema
            { type: 'object', properties: { kairomone: KAIROMONE, command: { type: 'string', enum: %w[list select] }, id: { type: 'string' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              case args['command']
              when 'list'
                store = instance(args, read: true)
                { success: true, profession: store.profession_status, kairomone: store.address }
              when 'select' then instance(args).select_profession(id: args['id'])
              else raise ::Kairomone::Error, 'Expected list or select'
              end
            end
          end
        end

        class Companion < Base
          COMMANDS = { 'status' => :companion_status, 'configure' => :configure_companion, 'context' => :companion_context, 'remember' => :remember_companion, 'recover' => :recover_companion_memory, 'revoke' => :revoke_companion_memory }.freeze
          READS = %w[status context].freeze

          def name; 'kairomone_companion'; end
          def description; 'Read or explicitly configure a Kairomone\'s companion settings; retrieve bounded context or ingest a reviewed summary only with current global and conversation consent. No model invocation, L0 change, XP award or automatic L1 promotion.'; end
          def input_schema
            { type: 'object', properties: { kairomone: KAIROMONE, command: { type: 'string', enum: COMMANDS.keys },
              arguments: { type: 'object' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              method = COMMANDS[args['command']]
              raise ::Kairomone::Error, 'Invalid companion command' unless method
              input = args.fetch('arguments', {})
              raise ::Kairomone::Error, 'Arguments must be an object' unless input.is_a?(Hash)
              store = instance(args, read: READS.include?(args['command']))
              allowed = store.method(method).parameters.map { |_kind, key| key.to_s }
              raise ::Kairomone::Error, 'Unexpected companion input fields' unless (input.keys - allowed).empty?
              result = store.public_send(method, **input.transform_keys(&:to_sym))
              result.is_a?(Hash) ? result.merge(kairomone: store.address) : result
            end
          end
        end

        class Growth < Base
          def name; 'kairomone_growth'; end
          def description; 'Growth runs. Autonomy exists only inside a run the owner started (run_start with the owner\'s words and a cycle count, an end time or both); each step carries run_id and the driver token run_start returned, and stops at the owner\'s stop, the end time or a host L0 change. run_stop is the owner\'s stop. No scheduler or web research is built in: workers provide actual retrieved evidence. Kairomone_Core sets no limit on cycles in a life; an operator policy may.'; end
          def input_schema
            { type: 'object', properties: {
              kairomone: KAIROMONE,
              command: { type: 'string', enum: %w[status run_start run_stop run_status request claim heartbeat commit fail], description: 'configure and stop (0.6) are gone: runs replace them' },
              owner_words: { type: 'string', description: 'run_start: the owner\'s own words asking for the run (at most 512 bytes)' },
              cycles: { type: 'integer', minimum: 1 }, end_at: { type: 'string', description: 'ISO 8601 time with zone' },
              run_id: { type: 'string' }, token: { type: 'string' },
              request_id: { type: 'string' }, topic: { type: 'string' },
              profession_id: { type: 'string' }, bias_applied: { type: 'boolean' }, worker_id: { type: 'string' },
              lease_seconds: { type: 'integer', minimum: 1, maximum: 900 }, claim_token: { type: 'string' },
              evidence: { type: 'object', description: 'Strict evidence: knowledge {title,content}, finding, uncertainty, counterexample, sources [{url,title,retrieved_at,excerpt,retrieval_reference,excerpt_sha256}]' }, reason: { type: 'string' }
            }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              read = args['command'] == 'status'
              store = instance(args, read: read)
              growth = store.autonomy
              case args['command']
              when 'status' then growth.status.merge('kairomone' => store.address)
              when 'run_start' then growth.run_start(owner_words: args['owner_words'], cycles: args['cycles'], end_at: args['end_at'])
              when 'run_stop' then growth.run_stop(reason: args.fetch('reason', 'Owner stop'))
              when 'run_status' then growth.run_status
              when 'request' then growth.request(run_id: args['run_id'], token: args['token'], request_id: args['request_id'], topic: args['topic'], profession_id: args.fetch('profession_id', 'generalist'), bias_applied: args.fetch('bias_applied', false))
              when 'claim' then growth.claim(run_id: args['run_id'], token: args['token'], worker_id: args['worker_id'], lease_seconds: args.fetch('lease_seconds', 300))
              when 'heartbeat' then growth.heartbeat(run_id: args['run_id'], token: args['token'], claim_token: args['claim_token'])
              when 'commit' then growth.commit(run_id: args['run_id'], token: args['token'], claim_token: args['claim_token'], evidence: args['evidence'])
              when 'fail' then growth.fail(run_id: args['run_id'], token: args['token'], claim_token: args['claim_token'], reason: args['reason'])
              when 'configure', 'stop'
                raise ::Kairomone::Error, "growth #{args['command']} belonged to the 0.6 lifetime budget, which 0.8 removed; use run_start / run_stop"
              else raise ::Kairomone::Error, 'Unknown growth command'
              end
            end
          end
        end

        class Backup < Base
          def name; 'kairomone_backup'; end
          def description; 'Create or verify a Kairomone backup (signed with this host\'s archive key), or restore one as a new listed Kairomone: restore takes a file in that Kairomone\'s backups directory and a target_id (its identity is listed, so the copy is a twin); restore_new takes a file in the host kairomone-inbox and the identity it must hold (dot_id), with target_id when that identity is already listed. Here only an archive this host signed restores; any other (a 0.6.1 backup, another machine\'s) restores only in the owner\'s own terminal, where its free text is shown first. Backups are unencrypted and may hold private text.'; end
          def input_schema
            { type: 'object', properties: { kairomone: KAIROMONE, command: { type: 'string', enum: %w[create verify restore restore_new] },
              file: { type: 'string', description: 'Backup basename: in this Kairomone\'s backups directory (restore, verify) or the host kairomone-inbox (restore_new)' },
              target_id: { type: 'string', description: 'Listing ID for the restored Kairomone: needed by restore, and by restore_new when the identity is already listed' },
              dot_id: { type: 'string', description: 'restore_new: the identity the archive must hold' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              case args['command']
              when 'create' then instance(args).create_backup
              when 'verify' then instance(args, read: true).verify_backup(file: args['file'])
              when 'restore' then instance(args).restore_backup(file: args['file'], target_id: args['target_id'])
              when 'restore_new'
                single_owner!
                ::Kairomone::Instance.new(bind: false).restore_new(file: args['file'], dot_id: args['dot_id'], target_id: args['target_id'])
              else raise ::Kairomone::Error, 'Expected create, verify, restore or restore_new'
              end
            end
          end
        end
      end
    end
  end
end
