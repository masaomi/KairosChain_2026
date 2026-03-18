# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'digest'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        # Agent-initiated Place-to-Place skill bridging.
        #
        # DEE design: the agent decides what to federate.
        # No automatic forwarding — each federation is a deliberate act.
        # Provenance chain tracks origin and path (BGP AS-path pattern).
        class MeetingFederate < KairosMcp::Tools::BaseTool
          def name
            'meeting_federate'
          end

          def description
            'Bridge skills from one Meeting Place to another, maintaining provenance chain. Agent-initiated federation (no automatic forwarding).'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting federate bridge relay provenance]
          end

          def related_tools
            %w[meeting_connect meeting_browse meeting_deposit]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                source_url: { type: 'string', description: 'Source Place URL (e.g. http://localhost:9200)' },
                source_token: { type: 'string', description: 'Session token for source Place (from meeting_connect)' },
                target_url: { type: 'string', description: 'Target Place URL (e.g. http://localhost:9201)' },
                target_token: { type: 'string', description: 'Session token for target Place (from meeting_connect)' },
                skill_ids: { type: 'array', items: { type: 'string' }, description: 'Specific skill IDs to federate (optional, defaults to all deposited skills)' },
                tags: { type: 'array', items: { type: 'string' }, description: 'Filter source skills by tags (optional)' }
              },
              required: %w[source_url source_token target_url target_token]
            }
          end

          def call(arguments)
            config = ::MMP.load_config
            unless config['enabled']
              return text_content(JSON.pretty_generate({ error: 'Meeting Protocol is disabled' }))
            end

            source_url = arguments['source_url'].chomp('/')
            source_token = arguments['source_token']
            target_url = arguments['target_url'].chomp('/')
            target_token = arguments['target_token']
            filter_ids = arguments['skill_ids']
            filter_tags = arguments['tags']

            begin
              # Resolve Place IDs for provenance chain (prefer place_id, fallback to URL)
              source_place_id = resolve_place_id(source_url) || source_url

              # Step 1: Browse source Place for deposited skills
              source_skills = browse_deposited_skills(source_url, source_token, tags: filter_tags)
              if source_skills.nil?
                return text_content(JSON.pretty_generate({ error: 'Failed to browse source Place' }))
              end

              # Filter by skill_ids if specified
              if filter_ids && !filter_ids.empty?
                source_skills = source_skills.select { |s| filter_ids.include?(s[:skill_id]) }
              end

              if source_skills.empty?
                return text_content(JSON.pretty_generate({
                  status: 'no_skills',
                  message: 'No deposited skills found on source Place matching criteria.'
                }))
              end

              # Step 2: For each skill, GET content from source + POST to target with provenance
              federated = []
              failed = []

              source_skills.each do |skill_meta|
                # GET full content from source
                content_result = get_skill_content(
                  source_url, source_token,
                  skill_meta[:skill_id],
                  owner_agent_id: skill_meta[:owner_agent_id]
                )

                unless content_result[:success]
                  failed << { skill_id: skill_meta[:skill_id], error: content_result[:error] }
                  next
                end

                # Build provenance for federation
                source_provenance = skill_meta[:trust_metadata]&.dig(:provenance) || {}
                source_deposited_at = skill_meta[:deposited_at]
                provenance = build_federation_provenance(source_provenance, source_place_id, content_result, source_deposited_at)

                # Sign content with this agent's key
                identity = ::MMP::Identity.new(config: config)
                crypto = identity.crypto
                content = content_result[:content]
                content_hash = Digest::SHA256.hexdigest(content)
                signature = crypto.has_keypair? ? crypto.sign(content) : nil

                # POST to target Place with provenance
                deposit_result = deposit_to_target(target_url, target_token, {
                  skill_id: skill_meta[:skill_id],
                  name: content_result[:name] || skill_meta[:name],
                  description: skill_meta[:description],
                  tags: skill_meta[:tags] || [],
                  format: content_result[:format] || 'markdown',
                  content: content,
                  content_hash: content_hash,
                  signature: signature,
                  provenance: provenance
                })

                if deposit_result && deposit_result[:status] == 'deposited'
                  federated << {
                    skill_id: skill_meta[:skill_id],
                    name: skill_meta[:name],
                    hop_count: provenance[:hop_count]
                  }
                else
                  error_msg = deposit_result&.dig(:reasons)&.join(', ') ||
                              deposit_result&.dig(:error) ||
                              'Unknown error'
                  failed << { skill_id: skill_meta[:skill_id], error: error_msg }
                end
              end

              output = {
                status: 'completed',
                source: source_url,
                target: target_url,
                federated: federated.size,
                failed: failed.size,
                details: {
                  federated: federated,
                  failed: failed
                }
              }

              output[:hint] = 'Use meeting_browse on target Place to verify federated skills.' if federated.any?

              text_content(JSON.pretty_generate(output))
            rescue StandardError => e
              text_content(JSON.pretty_generate({ error: 'Federation failed', message: e.message }))
            end
          end

          private

          # Browse source Place for deposited_skill entries only
          def browse_deposited_skills(url, token, tags: nil)
            params = { 'type' => 'deposited_skill', 'limit' => '50' }
            params['tags'] = tags.join(',') if tags && !tags.empty?

            query = URI.encode_www_form(params)
            uri = URI.parse("#{url}/place/v1/board/browse?#{query}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 5; http.read_timeout = 10
            req = Net::HTTP::Get.new(uri)
            req['Authorization'] = "Bearer #{token}"
            response = http.request(req)
            return nil unless response.is_a?(Net::HTTPSuccess)

            data = JSON.parse(response.body, symbolize_names: true)
            (data[:entries] || []).map do |e|
              {
                skill_id: e[:skill_id],
                name: e[:name],
                description: e[:description],
                tags: e[:tags],
                owner_agent_id: e[:agent_id],
                deposited_at: e[:deposited_at],
                trust_metadata: e[:trust_metadata]
              }
            end
          rescue StandardError
            nil
          end

          # GET skill content from source Place
          def get_skill_content(url, token, skill_id, owner_agent_id: nil)
            path = "/place/v1/skill_content/#{URI.encode_www_form_component(skill_id)}"
            path += "?owner=#{URI.encode_www_form_component(owner_agent_id)}" if owner_agent_id
            uri = URI.parse("#{url}#{path}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 5; http.read_timeout = 10
            req = Net::HTTP::Get.new(uri)
            req['Authorization'] = "Bearer #{token}"
            response = http.request(req)
            if response.is_a?(Net::HTTPSuccess)
              data = JSON.parse(response.body, symbolize_names: true)
              {
                success: true,
                name: data[:name],
                content: data[:content],
                content_hash: data[:content_hash],
                format: data[:format],
                depositor_id: data[:depositor_id]
              }
            else
              { success: false, error: "HTTP #{response.code}" }
            end
          rescue StandardError => e
            { success: false, error: e.message }
          end

          # Resolve Place's instance ID from /place/v1/info (unauthenticated).
          # Returns nil on failure (caller should fallback to URL).
          def resolve_place_id(url)
            uri = URI.parse("#{url}/place/v1/info")
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 3; http.read_timeout = 5
            req = Net::HTTP::Get.new(uri)
            response = http.request(req)
            return nil unless response.is_a?(Net::HTTPSuccess)
            data = JSON.parse(response.body, symbolize_names: true)
            data[:place_id]
          rescue StandardError
            nil
          end

          # Build provenance for the federated deposit.
          # source_place_id: resolved Place instance ID (or URL as fallback).
          def build_federation_provenance(source_provenance, source_place_id, content_result, source_deposited_at)
            if source_provenance[:hop_count].to_i > 0
              # Already federated: increment hop, append source to via
              {
                origin_place_id: source_provenance[:origin_place_id],
                origin_agent_id: source_provenance[:origin_agent_id] || content_result[:depositor_id],
                via: (source_provenance[:via] || []) + [source_place_id],
                hop_count: source_provenance[:hop_count].to_i + 1,
                deposited_at_origin: source_provenance[:deposited_at_origin]
              }
            else
              # First federation: source Place is the origin
              {
                origin_place_id: source_place_id,
                origin_agent_id: content_result[:depositor_id],
                via: [source_place_id],
                hop_count: 1,
                deposited_at_origin: source_deposited_at || Time.now.utc.iso8601
              }
            end
          end

          # POST skill to target Place with provenance
          def deposit_to_target(url, token, skill)
            uri = URI.parse("#{url}/place/v1/deposit")
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 5; http.read_timeout = 15
            req = Net::HTTP::Post.new(uri.path)
            req['Content-Type'] = 'application/json'
            req['Authorization'] = "Bearer #{token}"
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
