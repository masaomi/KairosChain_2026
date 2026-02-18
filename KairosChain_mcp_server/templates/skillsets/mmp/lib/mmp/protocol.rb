# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'

module MMP
  class Protocol
    PROTOCOL_VERSION = '1.0.0'

    CORE_ACTIONS = %w[introduce goodbye error].freeze

    ACTIONS = %w[
      introduce goodbye error
      offer_skill request_skill accept decline reflect skill_content
      propose_extension evaluate_extension adopt_extension share_extension
    ].freeze

    attr_reader :protocol_loader, :supported_extensions, :evolution, :compatibility

    Message = Struct.new(:id, :action, :from, :to, :timestamp, :payload, :in_reply_to, :protocol_version, keyword_init: true) do
      def to_h
        { id: id, action: action, from: from, to: to, timestamp: timestamp, payload: payload, in_reply_to: in_reply_to, protocol_version: protocol_version }.compact
      end
      def to_json(*args) = to_h.to_json(*args)
    end

    def initialize(identity:, knowledge_root: nil, evolution_config: {})
      @identity = identity
      @pending_offers = {}
      @pending_requests = {}
      @knowledge_root = knowledge_root
      @supported_extensions = []

      if @knowledge_root && File.directory?(@knowledge_root.to_s)
        @protocol_loader = ProtocolLoader.new(knowledge_root: @knowledge_root)
        load_protocols
        @evolution = ProtocolEvolution.new(knowledge_root: @knowledge_root, config: evolution_config)
      end

      @compatibility = Compatibility.new(
        protocol_version: PROTOCOL_VERSION,
        extensions: @supported_extensions,
        actions: supported_actions
      )
    end

    def load_protocols
      return unless @protocol_loader
      result = @protocol_loader.load_all
      @supported_extensions = @protocol_loader.extensions
      result
    rescue StandardError => e
      warn "[MMP::Protocol] Error loading protocols: #{e.message}"
      { error: e.message, fallback: true }
    end

    def supported_actions
      if @protocol_loader&.available_actions&.any?
        @protocol_loader.available_actions
      else
        ACTIONS
      end
    end

    def action_supported?(action) = supported_actions.include?(action)
    def core_actions = @protocol_loader&.core_actions&.any? ? @protocol_loader.core_actions : CORE_ACTIONS

    def create_introduce
      intro = @identity.introduce
      intro[:extensions] = @supported_extensions
      create_message(action: 'introduce', payload: intro)
    end

    def create_goodbye(to:, reason: 'session_complete', summary: nil)
      create_message(action: 'goodbye', to: to, payload: { reason: reason, summary: summary }.compact)
    end

    def create_error(to:, error_code:, message:, recoverable: true, in_reply_to: nil, details: nil)
      create_message(action: 'error', to: to, in_reply_to: in_reply_to, payload: { error_code: error_code, message: message, recoverable: recoverable, details: details }.compact)
    end

    def create_offer_skill(skill_id:, to: nil)
      skill = find_skill(skill_id)
      raise ArgumentError, "Skill not found: #{skill_id}" unless skill
      raise ArgumentError, "Skill is not public: #{skill_id}" unless skill[:public]
      msg = create_message(action: 'offer_skill', to: to, payload: { skill_id: skill[:id], skill_name: skill[:name], skill_summary: skill[:summary], skill_format: skill[:format], content_hash: skill[:content_hash] })
      @pending_offers[msg.id] = { skill_id: skill_id, skill: skill, created_at: Time.now.utc }
      msg
    end

    def create_request_skill(description:, to: nil)
      msg = create_message(action: 'request_skill', to: to, payload: { description: description, accepted_formats: @identity.config.dig('skill_exchange', 'allowed_formats') || %w[markdown] })
      @pending_requests[msg.id] = { description: description, created_at: Time.now.utc }
      msg
    end

    def create_accept(in_reply_to:, to:)
      create_message(action: 'accept', to: to, in_reply_to: in_reply_to, payload: { accepted: true, message: 'Offer accepted. Please send the skill content.' })
    end

    def create_decline(in_reply_to:, to:, reason: nil)
      create_message(action: 'decline', to: to, in_reply_to: in_reply_to, payload: { accepted: false, reason: reason || 'Offer declined.' })
    end

    def create_skill_content(in_reply_to:, to:, skill_id:, content:)
      skill = find_skill(skill_id)
      raise ArgumentError, "Skill not found: #{skill_id}" unless skill
      create_message(action: 'skill_content', to: to, in_reply_to: in_reply_to, payload: { skill_id: skill[:id], skill_name: skill[:name], format: skill[:format], content: content, content_hash: Digest::SHA256.hexdigest(content) })
    end

    def create_reflect(to:, reflection:, in_reply_to: nil)
      create_message(action: 'reflect', to: to, in_reply_to: in_reply_to, payload: { reflection: reflection })
    end

    def process_message(raw_message)
      msg_data = raw_message.is_a?(String) ? JSON.parse(raw_message, symbolize_names: true) : deep_symbolize_keys(raw_message)
      action = msg_data[:action]
      return { status: 'error', message: "Unknown action: #{action}" } unless action_supported?(action)

      case action
      when 'introduce' then process_introduce(msg_data)
      when 'goodbye' then { status: 'goodbye', from: msg_data[:from] }
      when 'error' then { status: 'error', from: msg_data[:from], error_code: msg_data.dig(:payload, :error_code) }
      when 'offer_skill' then process_offer_skill(msg_data)
      when 'request_skill' then process_request_skill(msg_data)
      when 'accept' then process_accept(msg_data)
      when 'decline' then process_decline(msg_data)
      when 'skill_content' then process_skill_content(msg_data)
      when 'reflect' then process_reflect(msg_data)
      else { status: 'unhandled', action: action }
      end
    end

    private

    def create_message(action:, to: nil, in_reply_to: nil, payload: {})
      Message.new(
        id: SecureRandom.uuid, action: action, from: @identity.introduce.dig(:identity, :instance_id),
        to: to, timestamp: Time.now.utc.iso8601, payload: payload, in_reply_to: in_reply_to, protocol_version: PROTOCOL_VERSION
      )
    end

    def find_skill(skill_id)
      @identity.introduce[:skills]&.find { |s| s[:id] == skill_id || s[:name] == skill_id }
    end

    def process_introduce(msg_data)
      { status: 'received', action: 'introduce', from: msg_data[:from], peer_identity: msg_data[:payload] }
    end

    def process_offer_skill(msg_data)
      payload = msg_data[:payload] || {}
      format = payload[:skill_format]
      allowed = @identity.config.dig('skill_exchange', 'allowed_formats') || %w[markdown]
      if allowed.include?(format)
        { status: 'received', action: 'offer_skill', from: msg_data[:from], skill_info: payload, can_accept: true }
      else
        { status: 'rejected', action: 'offer_skill', reason: "Format '#{format}' not accepted" }
      end
    end

    def process_request_skill(msg_data)
      { status: 'received', action: 'request_skill', from: msg_data[:from], request: msg_data[:payload] }
    end

    def process_accept(msg_data)
      pending = @pending_offers[msg_data[:in_reply_to]]
      { status: 'accepted', action: 'accept', from: msg_data[:from], original_offer: pending, next_step: 'send_skill_content' }
    end

    def process_decline(msg_data)
      @pending_offers.delete(msg_data[:in_reply_to])
      @pending_requests.delete(msg_data[:in_reply_to])
      { status: 'declined', action: 'decline', from: msg_data[:from], reason: msg_data.dig(:payload, :reason) }
    end

    def process_skill_content(msg_data)
      payload = msg_data[:payload] || {}
      content = payload[:content]
      content_hash = payload[:content_hash]
      if content_hash && Digest::SHA256.hexdigest(content || '') != content_hash
        return { status: 'error', action: 'skill_content', error: 'Content hash mismatch' }
      end
      { status: 'received', action: 'skill_content', from: msg_data[:from], skill_name: payload[:skill_name], format: payload[:format], content: content, content_hash: Digest::SHA256.hexdigest(content || '') }
    end

    def process_reflect(msg_data)
      { status: 'received', action: 'reflect', from: msg_data[:from], reflection: msg_data.dig(:payload, :reflection), interaction_complete: true }
    end

    def deep_symbolize_keys(hash)
      return hash unless hash.is_a?(Hash)
      hash.each_with_object({}) do |(key, value), result|
        sym_key = key.respond_to?(:to_sym) ? key.to_sym : key
        result[sym_key] = case value
                          when Hash then deep_symbolize_keys(value)
                          when Array then value.map { |v| v.is_a?(Hash) ? deep_symbolize_keys(v) : v }
                          else value
                          end
      end
    end
  end
end
