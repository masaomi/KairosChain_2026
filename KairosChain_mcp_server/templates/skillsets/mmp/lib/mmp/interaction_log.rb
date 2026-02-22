# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'

module MMP
  class InteractionLog
    INTERACTION_TYPES = %w[meeting_started introduce_sent introduce_received skill_offered skill_requested offer_accepted offer_declined skill_transferred interaction_reflected meeting_ended].freeze

    def initialize(chain_adapter: nil, workspace_root: nil)
      @chain_adapter = chain_adapter || default_chain_adapter
      @workspace_root = workspace_root
      @current_session = nil
    end

    def start_session(peer_id:)
      @current_session = { id: generate_session_id, peer_id: peer_id, started_at: Time.now.utc.iso8601, messages: [] }
      log_interaction(type: 'meeting_started', peer_id: peer_id, metadata: { session_id: @current_session[:id] })
      @current_session[:id]
    end

    def end_session(summary: nil)
      return unless @current_session
      log_interaction(type: 'meeting_ended', peer_id: @current_session[:peer_id], metadata: { session_id: @current_session[:id], message_count: @current_session[:messages].length, summary: summary })
      record_session_to_chain
      session_id = @current_session[:id]
      @current_session = nil
      session_id
    end

    def log_outgoing(message)
      msg_data = message.respond_to?(:to_h) ? message.to_h : message
      interaction_type = map_action_to_type(msg_data[:action], 'outgoing')
      log_interaction(type: interaction_type, direction: 'outgoing', message_id: msg_data[:id], action: msg_data[:action], peer_id: msg_data[:to], metadata: extract_log_metadata(msg_data))
    end

    def log_incoming(message)
      msg_data = message.is_a?(String) ? JSON.parse(message, symbolize_names: true) : message
      interaction_type = map_action_to_type(msg_data[:action], 'incoming')
      log_interaction(type: interaction_type, direction: 'incoming', message_id: msg_data[:id], action: msg_data[:action], peer_id: msg_data[:from], metadata: extract_log_metadata(msg_data))
    end

    def log_skill_exchange(skill_name:, skill_hash:, direction:, peer_id:, provenance: nil)
      metadata = { skill_name: skill_name, content_hash: skill_hash, transferred_at: Time.now.utc.iso8601 }
      metadata[:provenance] = { origin: provenance[:origin], hop_count: provenance[:hop_count], chain: provenance[:provenance_chain] } if provenance
      log_interaction(type: 'skill_transferred', direction: direction.to_s, peer_id: peer_id, metadata: metadata)
    end

    def skill_transfer_history(limit: 100)
      all_interactions(limit: limit * 2).select { |i| i[:type] == 'skill_transferred' }.last(limit)
    end

    def history_with_peer(peer_id, limit: 50)
      all_interactions.select { |i| i[:peer_id] == peer_id }.last(limit)
    end

    def all_interactions(limit: 100)
      interactions = []
      @chain_adapter.chain_data.each do |block|
        block_data = block.respond_to?(:data) ? block.data : (block.is_a?(Hash) ? block[:data] : [])
        Array(block_data).each do |item|
          parsed = parse_interaction_data(item)
          interactions << parsed if parsed
        end
      end
      interactions.last(limit)
    end

    def summary
      interactions = all_interactions(limit: 1000)
      { total_interactions: interactions.length, unique_peers: interactions.map { |i| i[:peer_id] }.compact.uniq.length, skills_transferred: interactions.count { |i| i[:type] == 'skill_transferred' }, sessions_completed: interactions.count { |i| i[:type] == 'meeting_ended' }, by_type: interactions.group_by { |i| i[:type] }.transform_values(&:count) }
    end

    private

    def default_chain_adapter
      MMP::KairosChainAdapter.new
    rescue StandardError
      MMP::NullChainAdapter.new
    end

    def map_action_to_type(action, direction)
      case action
      when 'introduce' then direction == 'outgoing' ? 'introduce_sent' : 'introduce_received'
      when 'offer_skill' then 'skill_offered'
      when 'request_skill' then 'skill_requested'
      when 'accept' then 'offer_accepted'
      when 'decline' then 'offer_declined'
      when 'skill_content' then 'skill_transferred'
      when 'reflect' then 'interaction_reflected'
      else "message_#{direction}"
      end
    end

    def log_interaction(type:, peer_id: nil, direction: nil, message_id: nil, action: nil, metadata: {})
      interaction = { type: type, timestamp: Time.now.utc.iso8601, peer_id: peer_id, direction: direction, message_id: message_id, action: action, metadata: metadata }.compact
      @current_session[:messages] << interaction if @current_session
      record_to_chain([interaction]) if %w[skill_transferred meeting_ended].include?(type)
      interaction
    end

    def extract_log_metadata(msg_data)
      payload = msg_data[:payload] || {}
      metadata = { in_reply_to: msg_data[:in_reply_to], protocol_version: msg_data[:protocol_version] }
      case msg_data[:action]
      when 'offer_skill', 'skill_content' then metadata.merge!(skill_name: payload[:skill_name], content_hash: payload[:content_hash])
      when 'request_skill' then metadata[:description] = payload[:description]&.slice(0, 100)
      end
      metadata.compact
    end

    def record_to_chain(interactions)
      return if interactions.empty?
      data = interactions.map { |i| { _type: 'interaction', **i }.to_json }
      @chain_adapter.record(data)
    end

    def record_session_to_chain
      return unless @current_session && !@current_session[:messages].empty?
      session_record = { _type: 'interaction_session', session_id: @current_session[:id], peer_id: @current_session[:peer_id], started_at: @current_session[:started_at], ended_at: Time.now.utc.iso8601, message_count: @current_session[:messages].length, messages_hash: Digest::SHA256.hexdigest(@current_session[:messages].to_json) }
      @chain_adapter.record([session_record.to_json])
    end

    def generate_session_id
      "session_#{Digest::SHA256.hexdigest("#{Time.now.to_f}#{rand}")[0, 12]}"
    end

    def parse_interaction_data(data_item)
      return nil unless data_item.is_a?(String)
      parsed = JSON.parse(data_item, symbolize_names: true)
      return nil unless %w[interaction interaction_session].include?(parsed[:_type])
      parsed
    rescue JSON::ParserError
      nil
    end
  end
end
