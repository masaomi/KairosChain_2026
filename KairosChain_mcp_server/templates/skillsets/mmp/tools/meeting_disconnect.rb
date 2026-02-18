# frozen_string_literal: true

require 'json'
require 'time'

module KairosMcp
  module SkillSets
    module MMP
      module Tools
        class MeetingDisconnect < KairosMcp::Tools::BaseTool
          def name
            'meeting_disconnect'
          end

          def description
            'Disconnect from the Meeting Place or peer and clean up the session.'
          end

          def category
            :meeting
          end

          def usecase_tags
            %w[meeting disconnect cleanup session]
          end

          def related_tools
            %w[meeting_connect meeting_acquire_skill]
          end

          def input_schema
            { type: 'object', properties: {} }
          end

          def call(arguments)
            connection = load_connection_state
            unless connection
              return text_content(JSON.pretty_generate({ status: 'not_connected', message: 'No active connection' }))
            end

            connected_at = connection['connected_at'] || connection[:connected_at]
            duration = connected_at ? (Time.now.utc - Time.parse(connected_at)).to_i : nil

            clear_connection_state

            result = {
              status: 'disconnected',
              session_summary: {
                connected_at: connected_at,
                disconnected_at: Time.now.utc.iso8601,
                duration_seconds: duration,
                peers_discovered: (connection['peers'] || connection[:peers] || []).length
              }
            }

            text_content(JSON.pretty_generate(result))
          rescue StandardError => e
            clear_connection_state
            text_content(JSON.pretty_generate({ status: 'disconnected_with_errors', error: e.message }))
          end

          private

          def load_connection_state
            state_file = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            return nil unless File.exist?(state_file)
            JSON.parse(File.read(state_file))
          rescue StandardError
            nil
          end

          def clear_connection_state
            state_file = File.join(KairosMcp.storage_dir, 'meeting_connection.json')
            File.delete(state_file) if File.exist?(state_file)
          rescue StandardError; end
        end
      end
    end
  end
end
