# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ProjectManagerSkillSet
      module Tools
        class PmItem < KairosMcp::Tools::BaseTool
          include ::ProjectManager::ToolHelpers

          def name
            'pm_item'
          end

          def description
            'Manage work items: add, update (status/salience/due/assignee/notes), add_dep, resolve_dep, ' \
            'link provenance. Routine writes advance the last-meaningful-touch marker; pass ' \
            'mechanical:true for bulk/migration writes (which never advance it) and touched_at to ' \
            'carry a migration source\'s own recency (INV-PM-6: carry, not restamp). ' \
            'Also holds the attention record: `attention` appends one entry per closed judgment ' \
            '(what was asked, how long the shown text was, and the OPERATOR\'S OWN answer to whether ' \
            'it was understood in one pass — never the agent\'s estimate of its own legibility), and ' \
            '`capacity` stores the operator\'s declaration of how many judgments the day has room for. ' \
            'Neither advances the marker: they observe the reader, not the work.'
          end

          def category
            :project_management
          end

          def usecase_tags
            %w[task item work management secretary seed migration]
          end

          def related_tools
            %w[pm_project pm_query pm_digest pm_record]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: { type: 'string', enum: %w[add update add_dep resolve_dep add_provenance get attention capacity],
                           description: 'Operation to perform' },
                id: { type: 'string', description: 'Item id (all commands except add)' },
                project_id: { type: 'string', description: 'Owning project id (add)' },
                title: { type: 'string', description: 'Item title (add/update)' },
                status: { type: 'string', enum: %w[open active awaiting_gate done dropped],
                          description: 'Lifecycle status (update)' },
                salience: { type: 'string', enum: %w[low normal high],
                            description: 'Coarse importance marker (add/update)' },
                due: { type: 'string', description: 'Deadline, ISO8601 (add/update)' },
                review_at: { type: 'string', description: 'Review date, ISO8601 (add/update)' },
                assignee: { type: 'string', description: 'Who holds this item — bare slot, optional (add/update)' },
                notes: { type: 'string', description: 'Free-form notes (add/update)' },
                dep_kind: { type: 'string', enum: %w[item world_event],
                            description: 'Blocking dependency kind (add_dep)' },
                dep_ref: { type: 'string', description: 'Dependency referent: item id or world-event label (add_dep/resolve_dep)' },
                dep_note: { type: 'string', description: 'Dependency note (add_dep)' },
                prov_kind: { type: 'string', description: 'Provenance kind, e.g. l2/attestation/external (add_provenance)' },
                prov_ref: { type: 'string', description: 'Provenance reference (add_provenance)' },
                mechanical: { type: 'boolean', description: 'Bulk/migration write: do not advance the marker (add/update/add_dep)' },
                touched_at: { type: 'string', description: 'Carried marker from a migration source, ISO8601 (add with mechanical:true)' },
                att_kind: { type: 'string', enum: %w[decide read review],
                            description: 'What the operator was asked to spend attention on (attention)' },
                lines: { type: 'integer', description: 'Length of the text the operator was shown, in lines (attention)' },
                grasp: { type: 'string', enum: %w[once reread unclear no_answer],
                         description: 'The OPERATOR\'S answer to "was this understood in one pass?". ' \
                                      'no_answer when asked and not answered — record it, do not omit it. ' \
                                      'Never fill this from the agent\'s own view of its output (attention)' },
                declared: { type: 'integer', description: 'How many judgments the operator says the day has room for; omit when asked and unanswered (capacity)' },
                date: { type: 'string', description: 'Day the declaration is for, YYYY-MM-DD; defaults to today UTC (capacity)' }
              },
              required: %w[command]
            }
          end

          def call(arguments)
            result = dispatch(arguments)
            text_content(JSON.pretty_generate(result))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          end

          private

          ATTR_KEYS = %w[title status salience due review_at assignee notes].freeze

          def dispatch(args)
            case args['command']
            when 'add'
              raise ArgumentError, 'project_id and title are required' unless args['project_id'] && args['title']

              pm_store.add_item(
                project_id: args['project_id'], title: args['title'],
                mechanical: args['mechanical'] || false, touched_at: args['touched_at'],
                **args.slice(*(ATTR_KEYS - ['title'])).transform_keys(&:to_sym)
              )
            when 'update'
              require_id!(args)
              pm_store.update_item(args['id'], args.slice(*ATTR_KEYS),
                                   mechanical: args['mechanical'] || false)
            when 'add_dep'
              require_id!(args)
              raise ArgumentError, 'dep_kind and dep_ref are required' unless args['dep_kind'] && args['dep_ref']

              pm_store.add_dep(args['id'], kind: args['dep_kind'], ref: args['dep_ref'],
                               note: args['dep_note'], mechanical: args['mechanical'] || false)
            when 'resolve_dep'
              require_id!(args)
              raise ArgumentError, 'dep_ref is required' unless args['dep_ref']

              pm_store.resolve_dep(args['id'], ref: args['dep_ref'])
            when 'add_provenance'
              require_id!(args)
              raise ArgumentError, 'prov_kind and prov_ref are required' unless args['prov_kind'] && args['prov_ref']

              pm_store.add_item_provenance(args['id'], { 'kind' => args['prov_kind'], 'ref' => args['prov_ref'] })
            when 'attention'
              require_id!(args)
              raise ArgumentError, 'att_kind is required' unless args['att_kind']

              pm_store.add_attention(args['id'], kind: args['att_kind'],
                                                 lines: args['lines'], grasp: args['grasp'])
            when 'capacity'
              # Not item-scoped: the declaration belongs to the operator's day, not
              # to any one piece of work. It lives on this tool rather than in a
              # sixth tool because the write is one line and a new tool would cost
              # a manifest entry, a registry class, and a projection — none of which
              # the single field earns.
              pm_store.declare_capacity(declared: args['declared'], date: args['date'])
            when 'get'
              require_id!(args)
              pm_store.fetch_item(args['id'])
            else
              raise ArgumentError, "unknown command: #{args['command']}"
            end
          end

          def require_id!(args)
            raise ArgumentError, 'id is required' unless args['id']
          end
        end
      end
    end
  end
end
