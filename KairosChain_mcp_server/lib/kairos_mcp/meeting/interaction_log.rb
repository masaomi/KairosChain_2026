# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
require_relative '../kairos_chain/chain'

module KairosMcp
  module Meeting
    # InteractionLog records all agent-to-agent interactions in the KairosChain.
    # This provides an immutable audit trail of all meetings and skill exchanges.
    class InteractionLog
      # Interaction types for categorization
      INTERACTION_TYPES = %w[
        meeting_started
        introduce_sent
        introduce_received
        skill_offered
        skill_requested
        offer_accepted
        offer_declined
        skill_transferred
        interaction_reflected
        meeting_ended
      ].freeze

      def initialize(chain: nil, workspace_root: nil)
        @chain = chain || KairosChain::Chain.new
        @workspace_root = workspace_root
        @current_session = nil
        @session_messages = []
      end

      # Start a new interaction session
      # @param peer_id [String] The peer's instance_id
      # @return [String] Session ID
      def start_session(peer_id:)
        @current_session = {
          id: generate_session_id,
          peer_id: peer_id,
          started_at: Time.now.utc.iso8601,
          messages: []
        }
        
        log_interaction(
          type: 'meeting_started',
          peer_id: peer_id,
          metadata: { session_id: @current_session[:id] }
        )

        @current_session[:id]
      end

      # End the current interaction session
      # @param summary [String, nil] Optional summary of the interaction
      def end_session(summary: nil)
        return unless @current_session

        log_interaction(
          type: 'meeting_ended',
          peer_id: @current_session[:peer_id],
          metadata: {
            session_id: @current_session[:id],
            message_count: @current_session[:messages].length,
            summary: summary
          }
        )

        # Record the full session to blockchain
        record_session_to_chain

        session_id = @current_session[:id]
        @current_session = nil
        session_id
      end

      # Log an outgoing message
      # @param message [MeetingProtocol::Message, Hash] The message being sent
      def log_outgoing(message)
        msg_data = message.respond_to?(:to_h) ? message.to_h : message
        
        interaction_type = case msg_data[:action]
                           when 'introduce' then 'introduce_sent'
                           when 'offer_skill' then 'skill_offered'
                           when 'request_skill' then 'skill_requested'
                           when 'accept' then 'offer_accepted'
                           when 'decline' then 'offer_declined'
                           when 'skill_content' then 'skill_transferred'
                           when 'reflect' then 'interaction_reflected'
                           else 'message_sent'
                           end

        log_interaction(
          type: interaction_type,
          direction: 'outgoing',
          message_id: msg_data[:id],
          action: msg_data[:action],
          peer_id: msg_data[:to],
          metadata: extract_log_metadata(msg_data)
        )
      end

      # Log an incoming message
      # @param message [Hash] The received message
      def log_incoming(message)
        msg_data = message.is_a?(String) ? JSON.parse(message, symbolize_names: true) : message
        
        interaction_type = case msg_data[:action]
                           when 'introduce' then 'introduce_received'
                           when 'offer_skill' then 'skill_offered'
                           when 'request_skill' then 'skill_requested'
                           when 'accept' then 'offer_accepted'
                           when 'decline' then 'offer_declined'
                           when 'skill_content' then 'skill_transferred'
                           when 'reflect' then 'interaction_reflected'
                           else 'message_received'
                           end

        log_interaction(
          type: interaction_type,
          direction: 'incoming',
          message_id: msg_data[:id],
          action: msg_data[:action],
          peer_id: msg_data[:from],
          metadata: extract_log_metadata(msg_data)
        )
      end

      # Log a skill exchange event
      # @param skill_name [String] Name of the skill
      # @param skill_hash [String] Content hash of the skill
      # @param direction [Symbol] :sent or :received
      # @param peer_id [String] The peer's instance_id
      def log_skill_exchange(skill_name:, skill_hash:, direction:, peer_id:)
        log_interaction(
          type: 'skill_transferred',
          direction: direction.to_s,
          peer_id: peer_id,
          metadata: {
            skill_name: skill_name,
            content_hash: skill_hash,
            transferred_at: Time.now.utc.iso8601
          }
        )
      end

      # Get interaction history for a specific peer
      # @param peer_id [String] The peer's instance_id
      # @param limit [Integer] Maximum number of records to return
      # @return [Array<Hash>] Interaction records
      def history_with_peer(peer_id, limit: 50)
        all_interactions.select { |i| i[:peer_id] == peer_id }.last(limit)
      end

      # Get all interaction history
      # @param limit [Integer] Maximum number of records to return
      # @return [Array<Hash>] All interaction records
      def all_interactions(limit: 100)
        interactions = []
        
        @chain.chain.each do |block|
          block.data.each do |data_item|
            parsed = parse_interaction_data(data_item)
            interactions << parsed if parsed && parsed[:type]&.start_with?('meeting_') || 
                                       INTERACTION_TYPES.include?(parsed&.dig(:type))
          end
        end

        interactions.last(limit)
      end

      # Get summary of interactions
      # @return [Hash] Summary statistics
      def summary
        interactions = all_interactions(limit: 1000)
        
        {
          total_interactions: interactions.length,
          unique_peers: interactions.map { |i| i[:peer_id] }.compact.uniq.length,
          skills_transferred: interactions.count { |i| i[:type] == 'skill_transferred' },
          sessions_completed: interactions.count { |i| i[:type] == 'meeting_ended' },
          by_type: interactions.group_by { |i| i[:type] }.transform_values(&:count)
        }
      end

      # Export interaction log to JSON
      # @param filepath [String] Path to export file
      def export_to_file(filepath)
        data = {
          exported_at: Time.now.utc.iso8601,
          summary: summary,
          interactions: all_interactions(limit: 10_000)
        }

        File.write(filepath, JSON.pretty_generate(data))
        filepath
      end

      private

      def log_interaction(type:, peer_id: nil, direction: nil, message_id: nil, action: nil, metadata: {})
        interaction = {
          type: type,
          timestamp: Time.now.utc.iso8601,
          peer_id: peer_id,
          direction: direction,
          message_id: message_id,
          action: action,
          metadata: metadata
        }.compact

        # Add to current session if active
        @current_session[:messages] << interaction if @current_session

        # For important events, record immediately to chain
        if %w[skill_transferred meeting_ended].include?(type)
          record_to_chain([interaction])
        end

        interaction
      end

      def extract_log_metadata(msg_data)
        payload = msg_data[:payload] || {}
        
        # Extract safe metadata (no full content)
        metadata = {
          in_reply_to: msg_data[:in_reply_to],
          protocol_version: msg_data[:protocol_version]
        }

        # Add action-specific metadata
        case msg_data[:action]
        when 'offer_skill', 'skill_content'
          metadata[:skill_name] = payload[:skill_name]
          metadata[:content_hash] = payload[:content_hash]
          metadata[:format] = payload[:format] || payload[:skill_format]
        when 'request_skill'
          metadata[:description] = payload[:description]&.slice(0, 100)
        when 'reflect'
          metadata[:has_reflection] = !payload[:reflection].nil?
        end

        metadata.compact
      end

      def record_to_chain(interactions)
        return if interactions.empty?

        data = interactions.map do |i|
          {
            _type: 'interaction',
            **i
          }.to_json
        end

        @chain.add_block(data)
      end

      def record_session_to_chain
        return unless @current_session
        return if @current_session[:messages].empty?

        # Create a session summary record
        session_record = {
          _type: 'interaction_session',
          session_id: @current_session[:id],
          peer_id: @current_session[:peer_id],
          started_at: @current_session[:started_at],
          ended_at: Time.now.utc.iso8601,
          message_count: @current_session[:messages].length,
          interaction_types: @current_session[:messages].map { |m| m[:type] }.uniq,
          messages_hash: Digest::SHA256.hexdigest(@current_session[:messages].to_json)
        }

        @chain.add_block([session_record.to_json])
      end

      def generate_session_id
        "session_#{Digest::SHA256.hexdigest("#{Time.now.to_f}#{rand}")[0, 12]}"
      end

      def parse_interaction_data(data_item)
        return nil unless data_item.is_a?(String)
        
        parsed = JSON.parse(data_item, symbolize_names: true)
        return nil unless parsed[:_type] == 'interaction' || parsed[:_type] == 'interaction_session'
        
        parsed
      rescue JSON::ParserError
        nil
      end
    end
  end
end
