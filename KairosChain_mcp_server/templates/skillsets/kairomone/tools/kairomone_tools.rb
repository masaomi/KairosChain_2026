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

        class Create < Base
          def name; 'kairomone_create'; end
          def description; 'Make a new Kairomone from the profile and first profession the owner accepted in this conversation (creation is their acceptance): show both to the owner in full first. profession is {template: ID} (kairomone_profession templates) or a drafted profession whose focus and habits come from the shipped vocabularies. The listing ID becomes its permanent identity.'; end
          def input_schema
            { type: 'object', properties: {
              kairomone: { type: 'string', description: 'Listing ID and identity of the new Kairomone' },
              profile: { type: 'object', description: 'name, kind, kind_label, appearance, personality[], voice, interests[]' },
              profession: { type: 'object', description: '{template: ID} or {name, description, focus[], habits{sources, depth, reflection, stance}}' },
              material_kind: { type: 'string', enum: ::Kairomone::Profile::MATERIAL_KINDS }, material_sha256: { type: 'string' }
            }, required: %w[kairomone profile profession], additionalProperties: false }
          end
          def call(args)
            output do
              single_owner!
              ::Kairomone::Host.new.create(listing_id: args['kairomone'], profile: args['profile'], profession: args['profession'],
                                           material_kind: args.fetch('material_kind', 'none'), material_sha256: args['material_sha256'])
            end
          end
        end

        class Profile < Base
          def name; 'kairomone_profile'; end
          def description; 'A Kairomone\'s profile (name, kind, appearance, personality, voice, interests). get shows the profile in force; material returns what to draft from: without kairomone, the host\'s material for a new Kairomone (the instruction mode, read only, and the character starters); with kairomone, that Kairomone\'s material and its seeds; propose stores a drafted version as a proposal, which changes nothing; proposals shows the ten newest waiting proposals in full (drawings by reference, seen on the status page) and the ten newest answered ones, with totals; accept puts one in force only when the owner accepted it in the conversation; history lists accepted versions. A new name is a new version.'; end
          def input_schema
            { type: 'object', properties: { kairomone: KAIROMONE, command: { type: 'string', enum: %w[get material propose proposals accept history] },
              profile: { type: 'object', description: 'propose: name, kind, kind_label, appearance, personality[], voice, interests[]' },
              material_kind: { type: 'string', enum: ::Kairomone::Profile::MATERIAL_KINDS }, material_sha256: { type: 'string' },
              proposal: { type: 'string', description: 'accept: the proposal sha256' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              case args['command']
              when 'get'
                store = instance(args, read: true)
                { success: true, kairomone: store.address, profile: store.profile }
              when 'material'
                # Unnamed: the host's material, for drafting a new Kairomone;
                # named: that Kairomone's material and seeds.
                single_owner!
                args['kairomone'].nil? ? ::Kairomone::Host.new.profile_material : instance(args, read: true).profile_material
              when 'proposals' then instance(args, read: true).proposals
              when 'history' then instance(args, read: true).profile_history
              when 'propose' then instance(args).propose_profile(fields: args['profile'], material_kind: args.fetch('material_kind', 'none'), material_sha256: args['material_sha256'])
              when 'accept' then instance(args).accept_profile(proposal: args['proposal'])
              else raise ::Kairomone::Error, 'Expected get, material, propose, proposals, accept or history'
              end
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
          def description; 'Create, get or list a Kairomone\'s dedicated canonical L1 knowledge. Create only on explicit user instruction; never overwrite an existing ID. Success requires a verified matching canonical ledger hash. This dedicated store is not searched by host knowledge_get. transplant copies one entry into the host\'s own L1, only when the owner asked for that entry, through the host\'s canonical knowledge path under a generated name; it is done when the host chain shows the record, else pending (the same transplant retried completes it); pending_transplants lists the open ones. The Kairomone keeps its entry.'; end
          def input_schema
            { type: 'object', properties: { kairomone: KAIROMONE, command: { type: 'string', enum: %w[create get list transplant pending_transplants] },
              id: { type: 'string' }, title: { type: 'string' }, content: { type: 'string' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              case args['command']
              when 'create' then instance(args).create_knowledge(id: args['id'], title: args['title'], content: args['content'])
              when 'get' then instance(args, read: true).read_knowledge(id: args['id'])
              when 'list' then instance(args, read: true).list_knowledge
              when 'transplant' then instance(args).transplant_knowledge(id: args['id'])
              when 'pending_transplants' then instance(args, read: true).pending_transplants
              else raise ::Kairomone::Error, 'Expected create, get, list, transplant or pending_transplants'
              end
            end
          end
        end

        class Art < Base
          def name; 'kairomone_art'; end
          def description; 'A Kairomone\'s drawing: an anthropomorphised, cute character of its kind, drawn by you from its profile as static SVG. propose checks the drawing (svg, g, path, circle, ellipse, rect, line, polyline, polygon, defs, gradients, stop, clipPath, title, desc; geometric and presentation attributes; viewBox; no style, href, event handlers or outside references; at most 64 KiB) and stores it as a proposal, which changes nothing; accept puts it in force only when the owner accepted it in the conversation; get returns the drawing in force (or a named one) checked again, or the built-in egg. A drawing is due at hatch (level 5) and at each later stage.'; end
          def input_schema
            { type: 'object', properties: { kairomone: KAIROMONE, command: { type: 'string', enum: %w[propose accept get] },
              svg: { type: 'string', description: 'propose: the drawing as SVG text' }, proposal: { type: 'string', description: 'accept: the proposal sha256' },
              sha256: { type: 'string', description: 'get: an accepted drawing (default: the one in force)' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              case args['command']
              when 'propose' then instance(args).propose_art(svg: args['svg'])
              when 'accept' then instance(args).accept_art(proposal: args['proposal'])
              when 'get' then instance(args, read: true).art_get(sha256: args['sha256'])
              else raise ::Kairomone::Error, 'Expected propose, accept or get'
              end
            end
          end
        end

        class Profession < Base
          def name; 'kairomone_profession'; end
          def description; 'A Kairomone\'s profession: what and how it learns, never what it may do. status shows the profession in force, its lineage and whether a branch is due (levels 10, 30, 100, 300, 600); offer stores exactly three professions derived from the current one, which change nothing; choose puts one in force only when the owner chose it in the conversation (or offer again for three new ones); templates and subjects list the shipped vocabularies; list and select keep the 0.6 template selection.'; end
          def input_schema
            { type: 'object', properties: { kairomone: KAIROMONE, command: { type: 'string', enum: %w[status offer choose templates subjects list select] },
              candidates: { type: 'array', items: { type: 'object' }, description: 'offer: three {name, description, focus[], habits{sources, depth, reflection, stance}}' },
              offer: { type: 'string', description: 'choose: the offer sha256' }, index: { type: 'integer', minimum: 0, maximum: 2 },
              id: { type: 'string', description: 'select: a template ID' } }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              case args['command']
              when 'status', 'list'
                store = instance(args, read: true)
                { success: true, profession: store.profession_status, kairomone: store.address }
              when 'offer' then instance(args).offer_professions(candidates: args['candidates'])
              when 'choose' then instance(args).choose_profession(offer: args['offer'], index: args['index'])
              when 'select' then instance(args).select_profession(id: args['id'])
              when 'templates' then { success: true, templates: ::Kairomone::Vocabulary.templates, habits: ::Kairomone::Vocabulary::HABITS }
              when 'subjects' then { success: true, subjects: ::Kairomone::Vocabulary.subjects, habits: ::Kairomone::Vocabulary::HABITS, kinds: ::Kairomone::Vocabulary.characters }
              else raise ::Kairomone::Error, 'Expected status, offer, choose, templates, subjects, list or select'
              end
            end
          end
        end

        class Companion < Base
          COMMANDS = { 'status' => :companion_status, 'history' => :companion_history, 'configure' => :configure_companion, 'context' => :companion_context, 'remember' => :remember_companion, 'recover' => :recover_companion_memory, 'revoke' => :revoke_companion_memory }.freeze
          READS = %w[status history context].freeze

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
              run_id: { type: 'string', description: 'The run a step belongs to; with run_status, answers for that run' },
              token: { type: 'string', description: 'The driver token run_start returned (not a claim token)' },
              request_id: { type: 'string' }, topic: { type: 'string' },
              profession_id: { type: 'string' }, bias_applied: { type: 'boolean' }, worker_id: { type: 'string' },
              lease_seconds: { type: 'integer', minimum: 1, maximum: 900 }, claim_token: { type: 'string' },
              evidence: { type: 'object', description: 'Strict evidence: knowledge {title,content}, finding, uncertainty, counterexample, sources [{url,title,retrieved_at,excerpt,retrieval_reference,excerpt_sha256}]' }, reason: { type: 'string' }
            }, required: ['command'], additionalProperties: false }
          end
          def call(args)
            output do
              read = args['command'] == 'status' # run_status records ends: it names its Kairomone like a write
              store = instance(args, read: read)
              growth = store.autonomy
              case args['command']
              when 'status' then growth.status.merge('kairomone' => store.address)
              when 'run_start' then growth.run_start(owner_words: args['owner_words'], cycles: args['cycles'], end_at: args['end_at'])
              when 'run_stop' then growth.run_stop(reason: args.fetch('reason', 'Owner stop'))
              when 'run_status' then growth.run_status(run_id: args['run_id'])
              when 'request' then growth.request(run_id: args['run_id'], token: args['token'], request_id: args['request_id'], topic: args['topic'], profession_id: args['profession_id'], bias_applied: args.fetch('bias_applied', false))
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
