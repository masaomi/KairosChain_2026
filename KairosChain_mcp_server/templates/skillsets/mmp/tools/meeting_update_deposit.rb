# frozen_string_literal: true

require 'json'
require 'yaml'
require 'digest'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingUpdateDeposit < KairosMcp::Tools::BaseTool
          def name
            'meeting_update_deposit'
          end

          def description
            'Update a skill you previously deposited to a connected Meeting Place. Re-reads the local skill content and replaces the deposited version. Agents who already acquired the old version are NOT auto-updated (DEE: pull-only).'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting update deposit version revision]
          end

          def related_tools
            %w[meeting_deposit meeting_withdraw meeting_browse]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                skill_name: {
                  type: 'string',
                  description: 'Name of the skill to update (must match an existing deposit)'
                },
                reason: {
                  type: 'string',
                  description: 'Reason for update (e.g., "v2.1: fixes from review")'
                },
                summary: {
                  type: 'string',
                  description: 'Updated summary for preview (optional, auto-generated if omitted)'
                },
                input_output: {
                  type: 'object',
                  properties: {
                    input: { type: 'string', description: 'What this skill takes as input' },
                    output: { type: 'string', description: 'What this skill produces as output' }
                  },
                  description: 'Input/output specification (optional)'
                }
              },
              required: %w[skill_name reason]
            }
          end

          def call(arguments)
            client = build_place_client
            return client if client.is_a?(String) # error message

            skill_name = arguments['skill_name']
            reason = arguments['reason']

            begin
              config = ::MMP.load_config
              identity = ::MMP::Identity.new(config: config)
              crypto = identity.crypto

              # Find the local skill by name
              skill = find_local_skill(skill_name)
              unless skill
                return text_content(JSON.pretty_generate({
                  error: 'skill_not_found',
                  message: "No local skill found with name: #{skill_name}",
                  hint: 'Ensure the skill exists in knowledge/ with publish: true in frontmatter.'
                }))
              end

              content = skill[:content]
              content_hash = Digest::SHA256.hexdigest(content)
              signature = crypto.has_keypair? ? crypto.sign(content) : nil

              body = {
                name: skill[:name],
                description: skill[:description],
                tags: skill[:tags],
                format: skill[:format],
                content: content,
                content_hash: content_hash,
                signature: signature,
                reason: reason
              }
              body[:summary] = arguments['summary'] if arguments['summary']
              body[:input_output] = arguments['input_output'] if arguments['input_output']

              result = client.update_deposit(skill_id: skill_name, skill: body)

              if result[:status] == 'updated'
                text_content(JSON.pretty_generate({
                  status: 'updated',
                  skill_id: skill_name,
                  previous_hash: result[:previous_hash],
                  new_hash: result[:new_hash],
                  updated_at: result[:updated_at],
                  chain_recorded: result[:chain_recorded],
                  reason: reason,
                  note: 'Agents who acquired the previous version are NOT auto-updated.'
                }))
              else
                text_content(JSON.pretty_generate({
                  error: result[:error] || 'Update failed',
                  message: result[:message],
                  reasons: result[:reasons]
                }.compact))
              end
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Update failed', message: e.message }))
            end
          end

          private

          def build_place_client
            config = ::MMP.load_config
            unless config['enabled']
              return text_content(JSON.pretty_generate({ error: 'Meeting Protocol is disabled' }))
            end

            connection = load_connection_state
            unless connection
              return text_content(JSON.pretty_generate({ error: 'Not connected', hint: 'Use meeting_connect first' }))
            end

            url = connection['url'] || connection[:url]
            token = connection['session_token'] || connection[:session_token]
            identity = ::MMP::Identity.new(config: config)
            client = ::MMP::PlaceClient.new(place_url: url, identity: identity, config: {})
            client.instance_variable_set(:@bearer_token, token)
            client.instance_variable_set(:@connected, true)
            client
          end

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError; nil
          end

          def find_local_skill(name)
            knowledge_dir = File.join(KairosMcp.data_dir, 'knowledge')
            return nil unless Dir.exist?(knowledge_dir)

            exclude_dirs = %w[trusted_peers received received_skills]
            Dir.glob(File.join(knowledge_dir, '**', '*.md')).each do |f|
              next if exclude_dirs.any? { |d| f.include?("/#{d}/") }
              content = File.read(f)
              next unless content.start_with?('---')
              parts = content.split(/^---\s*$/, 3)
              next if parts.length < 3
              frontmatter = YAML.safe_load(parts[1]) rescue next
              next unless frontmatter.is_a?(Hash)
              next unless frontmatter['publish'] == true

              skill_name = frontmatter['name'] || frontmatter['title'] || File.basename(f, '.md')
              next unless skill_name == name

              return {
                name: skill_name,
                description: frontmatter['description'] || '',
                tags: frontmatter['tags'] || [],
                format: 'yaml_frontmatter',
                content: content
              }
            end
            nil
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
