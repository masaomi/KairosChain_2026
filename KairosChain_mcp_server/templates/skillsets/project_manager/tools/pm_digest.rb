# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ProjectManagerSkillSet
      module Tools
        class PmDigest < KairosMcp::Tools::BaseTool
          include ::ProjectManager::ToolHelpers

          def name
            'pm_digest'
          end

          def description
            'Produce the session-start status digest: due/approaching commitments, items awaiting a ' \
            'human gate, and dormant-but-important items (split into neglected vs legitimately ' \
            'waiting — blocked or gated items surface as "still waiting", not as neglect). ' \
            'Also reports what no bucket covered: uncovered_count, and uncovered_stale, which names ' \
            'every uncovered item already past the dormancy threshold, oldest first, at any salience ' \
            '(dormancy proper is computed at high salience only, so those would otherwise be invisible). ' \
            'healthy_count is a deprecated alias of uncovered_count; the name is wrong because the ' \
            'number mixes work that is fine with work nobody is watching. ' \
            'Read-only. How the digest is presented is the consumer\'s concern (secretary mode, Web UI).'
          end

          def category
            :project_management
          end

          def usecase_tags
            %w[digest session_start surfacing dormant keep_fire secretary]
          end

          def related_tools
            %w[pm_query pm_item]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                dormancy_days: { type: 'integer', description: 'Override the dormancy threshold (default from config, 14)' },
                approaching_days: { type: 'integer', description: 'Override the deadline horizon (default from config, 7)' }
              }
            }
          end

          def call(arguments)
            # Digest guards its config container, but only what reaches it. This
            # builds that container and writes overrides into it first, so a
            # scalar `digest:` in pm.yml raised here — one step upstream of the
            # guard — whenever an override was passed. Guarding at the point of
            # construction is the whole point: the same shape has now been fixed
            # one step short three times in this file's history.
            settings = pm_config.is_a?(Hash) ? pm_config['digest'] : nil
            config = settings.is_a?(Hash) ? settings.dup : {}
            config['dormancy_days'] = arguments['dormancy_days'] if arguments['dormancy_days']
            config['approaching_days'] = arguments['approaching_days'] if arguments['approaching_days']
            digest = ::ProjectManager::Digest.new(pm_store, config)
            out = digest.compute
            # An unreadable pm.yml no longer takes this tool down, and that is
            # only half a fix: defaults that look like the operator's settings
            # are worse than the outage. The reason travels with the digest so
            # the consumer says the file was ignored instead of reporting
            # thresholds nobody chose.
            out[:config_error] = pm_config_error if pm_config_error
            text_content(JSON.pretty_generate(out))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          end
        end
      end
    end
  end
end
