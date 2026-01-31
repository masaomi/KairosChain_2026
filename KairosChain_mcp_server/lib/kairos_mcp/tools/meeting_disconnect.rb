# frozen_string_literal: true

require_relative 'base_tool'
require 'net/http'
require 'uri'
require 'json'
require 'securerandom'

module KairosMcp
  module Tools
    # Tool for disconnecting from a Meeting Place and cleaning up.
    class MeetingDisconnect < BaseTool
      def name
        'meeting_disconnect'
      end

      def description
        <<~DESC
          Disconnect from the Meeting Place and clean up the session.
          
          This will:
          - Unregister from the Meeting Place (if registered)
          - Clear the local connection state
          - Log a summary of the session
          
          Use this when you're done with agent-to-agent communication.
          
          Example: meeting_disconnect()
        DESC
      end

      def category
        :meeting
      end

      def usecase_tags
        %w[meeting disconnect cleanup session end]
      end

      def examples
        [
          {
            title: 'Disconnect from Meeting Place',
            code: 'meeting_disconnect()'
          }
        ]
      end

      def related_tools
        %w[meeting_connect meeting_get_skill_details meeting_acquire_skill]
      end

      def input_schema
        {
          type: 'object',
          properties: {}
        }
      end

      def call(arguments)
        # Check if Meeting Protocol is enabled
        unless meeting_enabled?
          return text_content(JSON.pretty_generate({
            error: 'Meeting Protocol is disabled',
            hint: 'Set enabled: true in config/meeting.yml to enable Meeting Protocol features'
          }))
        end

        # Load connection state
        connection = load_connection_state
        unless connection
          return text_content(JSON.pretty_generate({
            status: 'not_connected',
            message: 'No active Meeting Place connection'
          }))
        end

        url = connection['url']
        connected_at = connection['connected_at']
        peers = connection['peers'] || []

        begin
          # Try to unregister from Meeting Place
          unregister_result = unregister_self(url)
          
          # Calculate session duration
          duration_seconds = nil
          if connected_at
            connected_time = Time.parse(connected_at)
            duration_seconds = (Time.now.utc - connected_time).to_i
          end

          # Clear connection state
          clear_connection_state

          # Build summary
          result = {
            status: 'disconnected',
            meeting_place: url,
            session_summary: {
              connected_at: connected_at,
              disconnected_at: Time.now.utc.iso8601,
              duration_seconds: duration_seconds,
              duration_human: duration_seconds ? format_duration(duration_seconds) : nil,
              peers_discovered: peers.length,
              peer_names: peers.map { |p| p['name'] || p[:name] }
            },
            unregistered: unregister_result[:success],
            state_cleared: true,
            hint: 'Use meeting_connect to connect again when needed.'
          }

          text_content(JSON.pretty_generate(result))
        rescue StandardError => e
          # Still try to clear local state even if unregister fails
          clear_connection_state
          
          text_content(JSON.pretty_generate({
            status: 'disconnected_with_errors',
            meeting_place: url,
            error: e.message,
            state_cleared: true,
            hint: 'Local state cleared. Remote unregistration may have failed.'
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

      def load_connection_state
        state_file = File.expand_path('../../../../storage/meeting_connection.json', __FILE__)
        return nil unless File.exist?(state_file)

        JSON.parse(File.read(state_file))
      rescue StandardError
        nil
      end

      def clear_connection_state
        state_file = File.expand_path('../../../../storage/meeting_connection.json', __FILE__)
        File.delete(state_file) if File.exist?(state_file)
      rescue StandardError
        # Best effort
      end

      def unregister_self(url)
        # Try to get our agent_id from stored state or generate it
        connection = load_connection_state
        agent_id = connection&.dig('self_agent_id') || generate_agent_id
        
        uri = URI.parse("#{url}/place/v1/unregister")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate({ agent_id: agent_id })

        response = http.request(request)
        
        if response.is_a?(Net::HTTPSuccess)
          { success: true }
        else
          { success: false, error: response.body }
        end
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def generate_agent_id
        config_path = find_meeting_config
        return 'kairos-unknown' unless config_path && File.exist?(config_path)

        require 'yaml'
        config = YAML.load_file(config_path) || {}
        identity = config['identity'] || {}
        name = identity['name'] || 'kairos'
        "#{name.downcase.gsub(/\s+/, '-')}-#{SecureRandom.hex(4)}"
      end

      def format_duration(seconds)
        if seconds < 60
          "#{seconds} seconds"
        elsif seconds < 3600
          minutes = seconds / 60
          "#{minutes} minute#{minutes > 1 ? 's' : ''}"
        else
          hours = seconds / 3600
          minutes = (seconds % 3600) / 60
          "#{hours} hour#{hours > 1 ? 's' : ''}, #{minutes} minute#{minutes > 1 ? 's' : ''}"
        end
      end
    end
  end
end
