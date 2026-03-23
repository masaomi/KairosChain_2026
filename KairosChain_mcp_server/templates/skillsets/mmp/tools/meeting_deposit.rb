# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'digest'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingDeposit < KairosMcp::Tools::BaseTool
          def name
            'meeting_deposit'
          end

          def description
            'Deposit your public skills to a connected Meeting Place so other agents can discover and acquire them.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting deposit publish share skills]
          end

          def related_tools
            %w[meeting_connect meeting_browse meeting_disconnect]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                skill_names: { type: 'array', items: { type: 'string' }, description: 'Specific skill names to deposit (optional, defaults to all public skills)' }
              },
              required: []
            }
          end

          def call(arguments)
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

            begin
              identity = ::MMP::Identity.new(config: config)
              crypto = identity.crypto

              # Scan for public skills
              public_skills = scan_public_skills(arguments['skill_names'])

              if public_skills.empty?
                return text_content(JSON.pretty_generate({
                  status: 'no_skills',
                  message: 'No public skills found to deposit. Set publish: true in skill frontmatter.',
                  total_knowledge: count_knowledge_files
                }))
              end

              # Deposit each skill
              deposited = []
              rejected = []

              public_skills.each do |skill|
                content = skill[:content]
                content_hash = Digest::SHA256.hexdigest(content)
                signature = crypto.has_keypair? ? crypto.sign(content) : nil

                result = deposit_to_place(url, token, {
                  skill_id: skill[:name],
                  name: skill[:name],
                  description: skill[:description],
                  tags: skill[:tags],
                  format: skill[:format],
                  content: content,
                  content_hash: content_hash,
                  signature: signature
                })

                if result && result[:status] == 'deposited'
                  deposited << { name: skill[:name], skill_id: skill[:name] }
                else
                  rejected << { name: skill[:name], error: result&.dig(:reasons)&.join(', ') || result&.dig(:error) || 'Unknown error' }
                end
              end

              output = {
                status: 'completed',
                deposited: deposited.size,
                rejected: rejected.size,
                details: {
                  deposited: deposited,
                  rejected: rejected
                }
              }

              output[:hint] = 'Use meeting_browse to verify your skills are visible.' if deposited.any?

              text_content(JSON.pretty_generate(output))
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Deposit failed', message: e.message }))
            end
          end

          private

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError; nil
          end

          # Scan for skills with `publish: true` in frontmatter.
          #
          # Visibility semantics:
          #   - `public: true`  → MMP direct exchange visibility (Identity#public_skills)
          #   - `publish: true` → Meeting Place deposit eligibility (this method)
          # These are intentionally separate: an agent may share skills directly
          # with peers (public) without depositing them to a Place (publish).
          def scan_public_skills(filter_names = nil)
            knowledge_dir = File.join(KairosMcp.data_dir, 'knowledge')
            return [] unless Dir.exist?(knowledge_dir)

            # Exclude internal knowledge dirs (trusted_peers, received, etc.)
            exclude_dirs = %w[trusted_peers received received_skills]
            skills = []
            Dir.glob(File.join(knowledge_dir, '**', '*.md')).each do |f|
              next if exclude_dirs.any? { |d| f.include?("/#{d}/") }
              content = File.read(f)
              next unless content.start_with?('---')
              parts = content.split(/^---\s*$/, 3)
              next if parts.length < 3
              frontmatter = YAML.safe_load(parts[1]) rescue next
              next unless frontmatter.is_a?(Hash)
              next unless frontmatter['publish'] == true

              name = frontmatter['name'] || frontmatter['title'] || File.basename(f, '.md')
              next if filter_names && !filter_names.include?(name)

              skills << {
                name: name,
                description: frontmatter['description'] || '',
                tags: frontmatter['tags'] || [],
                format: content.start_with?('---') ? 'yaml_frontmatter' : 'markdown',
                content: content
              }
            end
            skills
          rescue StandardError
            []
          end

          def count_knowledge_files
            knowledge_dir = File.join(KairosMcp.data_dir, 'knowledge')
            return 0 unless Dir.exist?(knowledge_dir)
            Dir.glob(File.join(knowledge_dir, '**', '*.md')).size
          rescue StandardError
            0
          end

          def deposit_to_place(url, token, skill)
            uri = URI.parse("#{url}/place/v1/deposit")
            http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = (uri.scheme == 'https')
            http.open_timeout = 5; http.read_timeout = 15
            req = Net::HTTP::Post.new(uri.path)
            req['Content-Type'] = 'application/json'
            req['Authorization'] = "Bearer #{token}" if token
            req.body = JSON.generate(skill)
            response = http.request(req)
            JSON.parse(response.body, symbolize_names: true)
          rescue StandardError => e
            { error: e.message }
          end
        end
      end
    end
  end
end
