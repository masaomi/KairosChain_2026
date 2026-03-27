# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Synoptis
      module Tools
        class TrustQuery < KairosMcp::Tools::BaseTool
          include ::Synoptis::ToolHelpers

          def name
            'trust_query'
          end

          def description
            'Calculate trust score for a subject based on its attestation history. ' \
            'Considers quality, freshness, diversity, velocity, and revocation penalty. ' \
            'Supports Meeting Place skills via "meeting:<skill_id>" and depositor trust via "meeting_agent:<agent_id>".'
          end

          def category
            :attestation
          end

          def usecase_tags
            %w[trust score query attestation reputation meeting]
          end

          def related_tools
            %w[attestation_list attestation_issue attestation_verify meeting_browse meeting_preview_skill]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                subject_ref: {
                  type: 'string',
                  description: 'The subject reference to calculate trust score for. ' \
                               'Use "meeting:<skill_id>" for Meeting Place skills, ' \
                               '"meeting_agent:<agent_id>" for depositor trust, ' \
                               'or a local ref (e.g., "skill://local_skill") for local attestation registry.'
                }
              },
              required: %w[subject_ref]
            }
          end

          # Allowed characters for skill_id and agent_id (alphanumeric, underscore, hyphen, dot)
          SAFE_ID_PATTERN = /\A[a-zA-Z0-9_\-\.]+\z/.freeze

          def call(arguments)
            ref = arguments['subject_ref'].to_s.strip

            result = case ref
                     when /\Ameeting:(.+)/
                       id = sanitize_id($1)
                       return text_content(JSON.pretty_generate({ error: 'Invalid skill_id' })) unless id
                       calculate_meeting_skill_trust(id)
                     when /\Ameeting_agent:(.+)/
                       id = sanitize_id($1)
                       return text_content(JSON.pretty_generate({ error: 'Invalid agent_id' })) unless id
                       calculate_meeting_agent_trust(id)
                     else
                       calculate_local_trust(ref)
                     end

            text_content(JSON.pretty_generate(result))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message }))
          end

          def sanitize_id(raw)
            stripped = raw.to_s.strip
            SAFE_ID_PATTERN.match?(stripped) ? stripped : nil
          end

          private

          # Local trust (v1, unchanged)
          def calculate_local_trust(ref)
            result = trust_scorer.calculate(ref)
            chain_status = registry.verify_chain(:proofs)
            result[:registry_integrity] = chain_status
            result[:source] = 'local'
            result
          end

          # Meeting Place skill trust (v2)
          def calculate_meeting_skill_trust(skill_id)
            adapter = meeting_trust_adapter
            unless adapter&.connected?
              return {
                subject_ref: "meeting:#{skill_id}",
                score: 0.0,
                source: 'unavailable',
                error: 'Not connected to a Meeting Place. Use meeting_connect first.'
              }
            end

            # Fetch skill data from Meeting Place
            skill_data = adapter.fetch_skill_data(skill_id)
            unless skill_data
              return {
                subject_ref: "meeting:#{skill_id}",
                score: 0.0,
                source: 'meeting_place',
                error: "Skill '#{skill_id}' not found or Meeting Place unreachable.",
                hint: 'This may indicate the skill does not exist, or a network/auth error. Check meeting_connect status.'
              }
            end

            # Calculate skill trust
            skill_result = trust_scorer.calculate_meeting_skill(skill_data, adapter: adapter)
            owner_id = skill_data[:owner_agent_id] || skill_data[:agent_id] || skill_data[:depositor_id]

            # Calculate depositor trust
            all_skills = adapter.fetch_all_skills
            depositor_result = trust_scorer.calculate_depositor(owner_id, all_skills, adapter: adapter)

            # Combined score
            combined = trust_scorer.calculate_combined(skill_result[:score], depositor_result[:score])
            rec = trust_scorer.recommendation(combined)

            # Build canonical URI
            place_url = resolve_place_url
            canonical = "skill://#{skill_id}?source=meeting&place=#{place_url}&owner=#{owner_id}"

            {
              subject_ref: canonical,
              score: combined,
              score_type: 'combined',
              layers: {
                skill_trust: skill_result,
                depositor_trust: depositor_result
              },
              recommendation: rec[:level],
              recommendation_reason: rec[:reason],
              data_quality: {
                source: 'meeting_place',
                place_url: place_url,
                remote_signals_discounted: true,
                anti_collusion_version: 'v2_simplified_bootstrap'
              }
            }
          end

          # Meeting Place depositor/agent trust (v2)
          def calculate_meeting_agent_trust(agent_id)
            adapter = meeting_trust_adapter
            unless adapter&.connected?
              return {
                subject_ref: "meeting_agent:#{agent_id}",
                score: 0.0,
                source: 'unavailable',
                error: 'Not connected to a Meeting Place. Use meeting_connect first.'
              }
            end

            all_skills = adapter.fetch_all_skills
            depositor_result = trust_scorer.calculate_depositor(agent_id, all_skills, adapter: adapter)

            place_url = resolve_place_url
            canonical = "agent://#{agent_id}?source=meeting&place=#{place_url}"

            rec = trust_scorer.recommendation(depositor_result[:score])

            {
              subject_ref: canonical,
              score: depositor_result[:score],
              score_type: 'depositor',
              layers: {
                depositor_trust: depositor_result
              },
              recommendation: rec[:level],
              recommendation_reason: rec[:reason],
              data_quality: {
                source: 'meeting_place',
                place_url: place_url,
                remote_signals_discounted: true,
                anti_collusion_version: 'v2_simplified_bootstrap'
              }
            }
          end

          def meeting_trust_adapter
            @_meeting_adapter = nil # no caching across calls — connection state may change
            connection = load_connection_state
            return nil unless connection

            config = trust_scorer.send(:synoptis_v2_config) rescue {}
            client = MeetingPlaceHttpClient.new(
              url: connection['url'] || connection[:url],
              token: connection['session_token'] || connection[:session_token]
            )
            ::Synoptis::MeetingTrustAdapter.new(
              place_client: client,
              config: config
            )
          end

          def load_connection_state
            f = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.exist?(f) ? JSON.parse(File.read(f)) : nil
          rescue StandardError
            nil
          end

          def resolve_place_url
            conn = load_connection_state
            (conn && (conn['url'] || conn[:url])) || 'unknown'
          end

          # Lightweight HTTP client for Meeting Place — mirrors MMP browse/preview patterns
          class MeetingPlaceHttpClient
            require 'net/http'
            require 'uri'
            require 'json'

            def initialize(url:, token:)
              @base_url = url
              @token = token
            end

            def browse(type: nil, search: nil, tags: nil, limit: 50)
              params = { 'limit' => limit.to_s }
              params['type'] = type if type
              params['search'] = search if search
              params['tags'] = Array(tags).join(',') if tags && !tags.empty?
              get('/place/v1/board/browse', params)
            end

            def preview_skill(skill_id:, owner: nil, first_lines: 0)
              params = { 'first_lines' => first_lines.to_s }
              params['owner'] = owner if owner
              encoded = URI.encode_www_form_component(skill_id)
              get("/place/v1/preview/#{encoded}", params)
            end

            def session_status
              { url: @base_url, connected: !@token.nil? }
            end

            def respond_to_missing?(method, include_private = false)
              super
            end

            private

            def get(path, params = {})
              query = params.empty? ? '' : "?#{URI.encode_www_form(params)}"
              uri = URI.parse("#{@base_url}#{path}#{query}")
              http = Net::HTTP.new(uri.host, uri.port)
              http.use_ssl = (uri.scheme == 'https')
              http.open_timeout = 5
              http.read_timeout = 10
              req = Net::HTTP::Get.new(uri)
              req['Authorization'] = "Bearer #{@token}" if @token
              response = http.request(req)
              if response.is_a?(Net::HTTPSuccess)
                JSON.parse(response.body, symbolize_names: true)
              end
            rescue StandardError
              nil
            end
          end
        end
      end
    end
  end
end
