# frozen_string_literal: true

require_relative 'base_tool'
require 'net/http'
require 'uri'
require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'

module KairosMcp
  module Tools
    # High-level tool for acquiring a skill from another agent.
    # This tool automates the full exchange process:
    # introduce → request_skill → accept → skill_content → save
    class MeetingAcquireSkill < BaseTool
      def name
        'meeting_acquire_skill'
      end

      def description
        <<~DESC
          Acquire a skill from another agent.
          
          This automates the full skill exchange process:
          1. Sends introduction to the peer
          2. Requests the specific skill
          3. Waits for and accepts the offer
          4. Receives the skill content
          5. Validates and saves the skill locally
          
          The skill will be saved to your knowledge/ directory (L1 layer).
          
          Example: meeting_acquire_skill(peer_id: "agent-xyz", skill_id: "translation_skill")
        DESC
      end

      def category
        :meeting
      end

      def usecase_tags
        %w[meeting skill acquire exchange transfer obtain]
      end

      def examples
        [
          {
            title: 'Acquire a skill',
            code: 'meeting_acquire_skill(peer_id: "agent-b-001", skill_id: "translation_skill")'
          },
          {
            title: 'Acquire and save to specific layer',
            code: 'meeting_acquire_skill(peer_id: "agent-b-001", skill_id: "translation_skill", save_to_layer: "L2")'
          }
        ]
      end

      def related_tools
        %w[meeting_connect meeting_get_skill_details meeting_disconnect]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            peer_id: {
              type: 'string',
              description: 'ID of the peer agent to acquire skill from'
            },
            skill_id: {
              type: 'string',
              description: 'ID of the skill to acquire'
            },
            save_to_layer: {
              type: 'string',
              enum: %w[L1 L2],
              description: 'Layer to save the skill (L1=knowledge, L2=context). Default: L1'
            }
          },
          required: %w[peer_id skill_id]
        }
      end

      def call(arguments)
        peer_id = arguments['peer_id']
        skill_id = arguments['skill_id']
        save_layer = arguments['save_to_layer'] || 'L1'

        # Check if Meeting Protocol is enabled
        unless meeting_enabled?
          return text_content(JSON.pretty_generate({
            error: 'Meeting Protocol is disabled',
            hint: 'Set enabled: true in config/meeting.yml to enable Meeting Protocol features'
          }))
        end

        # Load connection state
        connection = load_connection_state
        unless connection && connection['connected']
          return text_content(JSON.pretty_generate({
            error: 'Not connected to Meeting Place',
            hint: 'Use meeting_connect first to connect to a Meeting Place'
          }))
        end

        # Find the peer
        peer = find_peer(connection, peer_id)
        unless peer
          return text_content(JSON.pretty_generate({
            error: "Peer not found: #{peer_id}",
            available_peers: connection['peers'].map { |p| p['agent_id'] || p[:agent_id] },
            hint: 'Use one of the available peer IDs from meeting_connect results'
          }))
        end

        endpoint = peer['endpoint'] || peer[:endpoint]
        
        begin
          # Step 1: Send introduction
          intro_result = send_introduction(endpoint)
          
          # Step 2: Request the skill
          request_result = request_skill(endpoint, skill_id)
          
          unless request_result[:success]
            return text_content(JSON.pretty_generate({
              error: "Failed to request skill",
              message: request_result[:error],
              peer_id: peer_id,
              skill_id: skill_id
            }))
          end

          # Step 3: Get skill content
          content_result = get_skill_content(endpoint, skill_id, request_result[:message_id])
          
          unless content_result[:success]
            return text_content(JSON.pretty_generate({
              error: "Failed to receive skill content",
              message: content_result[:error],
              peer_id: peer_id,
              skill_id: skill_id
            }))
          end

          # Step 4: Validate content
          validation = validate_skill(content_result)
          
          unless validation[:valid]
            return text_content(JSON.pretty_generate({
              error: "Skill validation failed",
              issues: validation[:issues],
              peer_id: peer_id,
              skill_id: skill_id
            }))
          end

          # Step 5: Save skill locally
          save_result = save_skill(content_result, save_layer, peer_id)
          
          unless save_result[:success]
            return text_content(JSON.pretty_generate({
              error: "Failed to save skill",
              message: save_result[:error],
              peer_id: peer_id,
              skill_id: skill_id
            }))
          end

          # Step 6: Send reflection/acknowledgment
          send_reflection(endpoint, skill_id, content_result[:message_id])

          # Build success response
          result = {
            status: 'acquired',
            peer_id: peer_id,
            peer_name: peer['name'] || peer[:name],
            skill: {
              id: skill_id,
              name: content_result[:skill_name],
              format: content_result[:format],
              size_bytes: content_result[:size_bytes],
              content_hash: content_result[:content_hash]
            },
            saved_to: {
              layer: save_layer,
              path: save_result[:path]
            },
            provenance: content_result[:provenance],
            exchange_log: {
              introduced: intro_result[:success],
              requested: request_result[:success],
              received: content_result[:success],
              validated: validation[:valid],
              saved: save_result[:success]
            },
            hint: "The skill has been saved to #{save_result[:path]}. You can now use it in your workflows."
          }

          text_content(JSON.pretty_generate(result))
        rescue StandardError => e
          text_content(JSON.pretty_generate({
            error: "Failed to acquire skill",
            message: e.message,
            peer_id: peer_id,
            skill_id: skill_id
          }))
        end
      end

      private

      def meeting_enabled?
        config_path = find_meeting_config
        return false unless config_path && File.exist?(config_path)

        require 'yaml'
        config = YAML.load_file(config_path) || {}
        config['enabled'] == true
      end

      def find_meeting_config
        workspace_config = File.expand_path('../../../../config/meeting.yml', __FILE__)
        return workspace_config if File.exist?(workspace_config)
        nil
      end

      def load_meeting_config
        config_path = find_meeting_config
        return {} unless config_path && File.exist?(config_path)

        require 'yaml'
        YAML.load_file(config_path) || {}
      end

      def load_connection_state
        state_file = File.expand_path('../../../../storage/meeting_connection.json', __FILE__)
        return nil unless File.exist?(state_file)

        JSON.parse(File.read(state_file))
      rescue StandardError
        nil
      end

      def find_peer(connection, peer_id)
        peers = connection['peers'] || connection[:peers] || []
        peers.find { |p| (p['agent_id'] || p[:agent_id]) == peer_id }
      end

      def send_introduction(endpoint)
        config = load_meeting_config
        identity = config['identity'] || {}

        uri = URI.parse("#{endpoint}/meeting/v1/introduce")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate({
          action: 'introduce',
          from: generate_agent_id,
          payload: {
            name: identity['name'] || 'KairosChain Instance',
            description: identity['description'] || 'A KairosChain agent',
            scope: identity['scope'] || 'general'
          }
        })

        response = http.request(request)
        
        if response.is_a?(Net::HTTPSuccess)
          { success: true }
        else
          { success: false, error: response.body }
        end
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def request_skill(endpoint, skill_id)
        uri = URI.parse("#{endpoint}/meeting/v1/request_skill")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate({
          description: "Requesting skill: #{skill_id}",
          skill_id: skill_id,
          to: 'peer'
        })

        response = http.request(request)
        
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          message = data['message'] || data
          { success: true, message_id: message['id'] || message[:id] || SecureRandom.uuid }
        else
          { success: false, error: response.body }
        end
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def get_skill_content(endpoint, skill_id, in_reply_to)
        uri = URI.parse("#{endpoint}/meeting/v1/skill_content")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate({
          skill_id: skill_id,
          in_reply_to: in_reply_to,
          to: generate_agent_id
        })

        response = http.request(request)
        
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          message = data['message'] || data
          packaged = data['packaged_skill'] || message['payload'] || {}
          
          # Extract content from message payload
          payload = message['payload'] || message[:payload] || {}
          content = payload['content'] || payload[:content]
          
          # If content not in payload, try to get it from skill_content response
          content ||= packaged['content'] || data['content']
          
          {
            success: true,
            message_id: message['id'] || message[:id] || SecureRandom.uuid,
            skill_name: payload['skill_name'] || payload[:skill_name] || skill_id,
            format: payload['format'] || payload[:format] || 'markdown',
            content: content,
            content_hash: payload['content_hash'] || payload[:content_hash] || packaged['content_hash'],
            size_bytes: content ? content.bytesize : 0,
            provenance: payload['provenance'] || payload[:provenance]
          }
        else
          { success: false, error: response.body }
        end
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def validate_skill(content_result)
        issues = []
        
        # Check content exists
        unless content_result[:content]
          issues << 'No content received'
          return { valid: false, issues: issues }
        end

        # Verify hash if provided
        if content_result[:content_hash]
          expected_hash = content_result[:content_hash]
          actual_hash = "sha256:#{Digest::SHA256.hexdigest(content_result[:content])}"
          
          if expected_hash != actual_hash
            issues << "Content hash mismatch: expected #{expected_hash}, got #{actual_hash}"
          end
        end

        # Check format
        config = load_meeting_config
        allowed_formats = config.dig('skill_exchange', 'allowed_formats') || ['markdown']
        
        unless allowed_formats.include?(content_result[:format])
          issues << "Format not allowed: #{content_result[:format]} (allowed: #{allowed_formats.join(', ')})"
        end

        # Check size
        max_size = config.dig('constraints', 'max_skill_size_bytes') || 100_000
        if content_result[:size_bytes] > max_size
          issues << "Content too large: #{content_result[:size_bytes]} bytes (max: #{max_size})"
        end

        { valid: issues.empty?, issues: issues }
      end

      def save_skill(content_result, layer, from_peer_id)
        skill_name = content_result[:skill_name].downcase.gsub(/\s+/, '_')
        
        # Determine save directory
        base_dir = File.expand_path('../../../../', __FILE__)
        save_dir = layer == 'L1' ? 
          File.join(base_dir, 'knowledge', skill_name) :
          File.join(base_dir, 'context', skill_name)
        
        FileUtils.mkdir_p(save_dir)
        
        # Determine file extension
        ext = case content_result[:format]
              when 'markdown' then '.md'
              when 'yaml' then '.yml'
              when 'json' then '.json'
              else '.md'
              end
        
        file_path = File.join(save_dir, "#{skill_name}#{ext}")
        
        # Add received metadata to content
        content_with_metadata = add_received_metadata(
          content_result[:content],
          content_result,
          from_peer_id
        )
        
        File.write(file_path, content_with_metadata)
        
        { success: true, path: file_path }
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def add_received_metadata(content, content_result, from_peer_id)
        # If content has YAML frontmatter, add received info
        if content.start_with?('---')
          lines = content.lines
          end_idx = lines[1..].index { |l| l.strip == '---' }
          
          if end_idx
            frontmatter_lines = lines[1..end_idx]
            rest = lines[(end_idx + 2)..]
            
            # Add received metadata
            new_frontmatter = frontmatter_lines.map(&:chomp).join("\n")
            new_frontmatter += "\nreceived_from: \"#{from_peer_id}\""
            new_frontmatter += "\nreceived_at: \"#{Time.now.utc.iso8601}\""
            new_frontmatter += "\ncontent_hash: \"#{content_result[:content_hash]}\"" if content_result[:content_hash]
            
            if content_result[:provenance]
              new_frontmatter += "\nprovenance:"
              new_frontmatter += "\n  origin: \"#{content_result[:provenance]['origin'] || content_result[:provenance][:origin]}\""
              new_frontmatter += "\n  hop_count: #{content_result[:provenance]['hop_count'] || content_result[:provenance][:hop_count] || 1}"
            end
            
            "---\n#{new_frontmatter}\n---\n#{rest.join}"
          else
            content
          end
        else
          # Add frontmatter
          <<~CONTENT
            ---
            name: #{content_result[:skill_name]}
            received_from: "#{from_peer_id}"
            received_at: "#{Time.now.utc.iso8601}"
            content_hash: "#{content_result[:content_hash]}"
            ---

            #{content}
          CONTENT
        end
      end

      def send_reflection(endpoint, skill_id, in_reply_to)
        uri = URI.parse("#{endpoint}/meeting/v1/reflect")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate({
          to: 'peer',
          in_reply_to: in_reply_to,
          reflection: "Successfully received and saved skill: #{skill_id}. Thank you for sharing!"
        })

        http.request(request)
      rescue StandardError
        # Reflection is best-effort, don't fail the whole operation
      end

      def generate_agent_id
        config = load_meeting_config
        identity = config['identity'] || {}
        name = identity['name'] || 'kairos'
        "#{name.downcase.gsub(/\s+/, '-')}-#{SecureRandom.hex(4)}"
      end
    end
  end
end
