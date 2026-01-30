# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'

module KairosMcp
  module Meeting
    # MeetingProtocol defines the semantic actions for agent-to-agent communication.
    # These are "speech acts" - not API commands, but intentional communication.
    class MeetingProtocol
      PROTOCOL_VERSION = '1.0.0'

      # Supported action types
      ACTIONS = %w[
        introduce
        offer_skill
        request_skill
        accept
        decline
        reflect
        skill_content
      ].freeze

      # Message structure for all protocol messages
      Message = Struct.new(
        :id,           # Unique message ID
        :action,       # Action type (introduce, offer_skill, etc.)
        :from,         # Sender identity (instance_id)
        :to,           # Recipient identity (instance_id, or nil for broadcast)
        :timestamp,    # ISO8601 timestamp
        :payload,      # Action-specific data
        :in_reply_to,  # Reference to previous message ID (for responses)
        :protocol_version,
        keyword_init: true
      ) do
        def to_h
          {
            id: id,
            action: action,
            from: from,
            to: to,
            timestamp: timestamp,
            payload: payload,
            in_reply_to: in_reply_to,
            protocol_version: protocol_version
          }.compact
        end

        def to_json(*args)
          to_h.to_json(*args)
        end
      end

      def initialize(identity:)
        @identity = identity
        @pending_offers = {}  # Track pending skill offers
        @pending_requests = {} # Track pending skill requests
      end

      # Create an introduce message
      def create_introduce
        create_message(
          action: 'introduce',
          payload: @identity.introduce
        )
      end

      # Create an offer_skill message
      # @param skill_id [String] ID of the skill to offer
      # @param to [String, nil] Recipient instance_id (nil for broadcast)
      def create_offer_skill(skill_id:, to: nil)
        skill = find_skill(skill_id)
        raise ArgumentError, "Skill not found: #{skill_id}" unless skill
        raise ArgumentError, "Skill is not public: #{skill_id}" unless skill[:public]

        message = create_message(
          action: 'offer_skill',
          to: to,
          payload: {
            skill_id: skill[:id],
            skill_name: skill[:name],
            skill_summary: skill[:summary],
            skill_format: skill[:format],
            content_hash: skill[:content_hash]
          }
        )

        @pending_offers[message.id] = {
          skill_id: skill_id,
          skill: skill,
          created_at: Time.now.utc
        }

        message
      end

      # Create a request_skill message
      # @param description [String] Description of what skill is needed
      # @param to [String, nil] Recipient instance_id (nil for broadcast)
      def create_request_skill(description:, to: nil)
        message = create_message(
          action: 'request_skill',
          to: to,
          payload: {
            description: description,
            accepted_formats: @identity.config.dig('skill_exchange', 'allowed_formats') || %w[markdown]
          }
        )

        @pending_requests[message.id] = {
          description: description,
          created_at: Time.now.utc
        }

        message
      end

      # Create an accept message (in response to offer_skill or request_skill)
      # @param in_reply_to [String] Message ID being accepted
      # @param to [String] Recipient instance_id
      def create_accept(in_reply_to:, to:)
        create_message(
          action: 'accept',
          to: to,
          in_reply_to: in_reply_to,
          payload: {
            accepted: true,
            message: 'Offer accepted. Please send the skill content.'
          }
        )
      end

      # Create a decline message
      # @param in_reply_to [String] Message ID being declined
      # @param to [String] Recipient instance_id
      # @param reason [String, nil] Optional reason for declining
      def create_decline(in_reply_to:, to:, reason: nil)
        create_message(
          action: 'decline',
          to: to,
          in_reply_to: in_reply_to,
          payload: {
            accepted: false,
            reason: reason || 'Offer declined.'
          }
        )
      end

      # Create a skill_content message (after accept)
      # @param in_reply_to [String] Accept message ID
      # @param to [String] Recipient instance_id
      # @param skill_id [String] ID of the skill to send
      # @param content [String] Full skill content
      def create_skill_content(in_reply_to:, to:, skill_id:, content:)
        skill = find_skill(skill_id)
        raise ArgumentError, "Skill not found: #{skill_id}" unless skill

        create_message(
          action: 'skill_content',
          to: to,
          in_reply_to: in_reply_to,
          payload: {
            skill_id: skill[:id],
            skill_name: skill[:name],
            format: skill[:format],
            content: content,
            content_hash: Digest::SHA256.hexdigest(content)
          }
        )
      end

      # Create a reflect message (post-interaction reflection)
      # @param in_reply_to [String, nil] Related message ID
      # @param to [String] Recipient instance_id
      # @param reflection [String] Reflection text
      def create_reflect(to:, reflection:, in_reply_to: nil)
        create_message(
          action: 'reflect',
          to: to,
          in_reply_to: in_reply_to,
          payload: {
            reflection: reflection,
            interaction_summary: summarize_interaction(in_reply_to)
          }
        )
      end

      # Process an incoming message
      # @param message_json [String, Hash] Incoming message
      # @return [Hash] Processing result with suggested response
      def process_message(message_json)
        msg_data = case message_json
                   when String
                     JSON.parse(message_json, symbolize_names: true)
                   when Hash
                     # Deep symbolize keys for consistency
                     deep_symbolize_keys(message_json)
                   else
                     message_json
                   end
        
        # Validate message structure
        validate_message!(msg_data)

        action = msg_data[:action]
        
        case action
        when 'introduce'
          process_introduce(msg_data)
        when 'offer_skill'
          process_offer_skill(msg_data)
        when 'request_skill'
          process_request_skill(msg_data)
        when 'accept'
          process_accept(msg_data)
        when 'decline'
          process_decline(msg_data)
        when 'skill_content'
          process_skill_content(msg_data)
        when 'reflect'
          process_reflect(msg_data)
        else
          { status: 'error', error: "Unknown action: #{action}" }
        end
      end

      private

      def create_message(action:, payload:, to: nil, in_reply_to: nil)
        Message.new(
          id: generate_message_id,
          action: action,
          from: @identity.introduce[:identity][:instance_id],
          to: to,
          timestamp: Time.now.utc.iso8601,
          payload: payload,
          in_reply_to: in_reply_to,
          protocol_version: PROTOCOL_VERSION
        )
      end

      def generate_message_id
        "msg_#{Digest::SHA256.hexdigest("#{Time.now.to_f}#{rand}")[0, 16]}"
      end

      def find_skill(skill_id)
        skills = @identity.introduce[:skills] || []
        skills.find { |s| s[:id] == skill_id }
      end

      def validate_message!(msg_data)
        required_fields = %i[id action from timestamp]
        missing = required_fields.select { |f| msg_data[f].nil? }
        
        raise ArgumentError, "Missing required fields: #{missing.join(', ')}" unless missing.empty?
        raise ArgumentError, "Unknown action: #{msg_data[:action]}" unless ACTIONS.include?(msg_data[:action])
      end

      def process_introduce(msg_data)
        {
          status: 'received',
          action: 'introduce',
          from: msg_data[:from],
          peer_identity: msg_data[:payload],
          suggested_response: create_introduce
        }
      end

      def process_offer_skill(msg_data)
        payload = msg_data[:payload] || {}
        format = payload[:skill_format]
        allowed = @identity.config.dig('skill_exchange', 'allowed_formats') || %w[markdown]

        if allowed.include?(format)
          {
            status: 'received',
            action: 'offer_skill',
            from: msg_data[:from],
            skill_info: payload,
            can_accept: true,
            suggested_response: :accept_or_decline
          }
        else
          {
            status: 'rejected',
            action: 'offer_skill',
            reason: "Format '#{format}' is not accepted. Allowed: #{allowed.join(', ')}",
            suggested_response: create_decline(
              in_reply_to: msg_data[:id],
              to: msg_data[:from],
              reason: "Format '#{format}' is not accepted"
            )
          }
        end
      end

      def process_request_skill(msg_data)
        {
          status: 'received',
          action: 'request_skill',
          from: msg_data[:from],
          request: msg_data[:payload],
          suggested_response: :offer_skill_or_decline
        }
      end

      def process_accept(msg_data)
        in_reply_to = msg_data[:in_reply_to]
        pending = @pending_offers[in_reply_to]

        if pending
          {
            status: 'accepted',
            action: 'accept',
            from: msg_data[:from],
            original_offer: pending,
            next_step: 'send_skill_content'
          }
        else
          {
            status: 'received',
            action: 'accept',
            from: msg_data[:from],
            note: 'No pending offer found for this accept'
          }
        end
      end

      def process_decline(msg_data)
        in_reply_to = msg_data[:in_reply_to]
        
        # Clean up pending offers/requests
        @pending_offers.delete(in_reply_to)
        @pending_requests.delete(in_reply_to)

        {
          status: 'declined',
          action: 'decline',
          from: msg_data[:from],
          reason: msg_data.dig(:payload, :reason)
        }
      end

      def process_skill_content(msg_data)
        payload = msg_data[:payload] || {}
        content = payload[:content]
        content_hash = payload[:content_hash]

        # Verify content hash
        calculated_hash = Digest::SHA256.hexdigest(content || '')
        
        if content_hash && calculated_hash != content_hash
          return {
            status: 'error',
            action: 'skill_content',
            error: 'Content hash mismatch - skill may be corrupted'
          }
        end

        {
          status: 'received',
          action: 'skill_content',
          from: msg_data[:from],
          skill_name: payload[:skill_name],
          format: payload[:format],
          content: content,
          content_hash: calculated_hash,
          suggested_response: :reflect
        }
      end

      def process_reflect(msg_data)
        {
          status: 'received',
          action: 'reflect',
          from: msg_data[:from],
          reflection: msg_data.dig(:payload, :reflection),
          interaction_complete: true
        }
      end

      def summarize_interaction(in_reply_to)
        # Simple summary - could be enhanced with full interaction history
        {
          referenced_message: in_reply_to,
          summarized_at: Time.now.utc.iso8601
        }
      end

      def deep_symbolize_keys(hash)
        return hash unless hash.is_a?(Hash)
        
        hash.each_with_object({}) do |(key, value), result|
          sym_key = key.respond_to?(:to_sym) ? key.to_sym : key
          result[sym_key] = case value
                            when Hash
                              deep_symbolize_keys(value)
                            when Array
                              value.map { |v| v.is_a?(Hash) ? deep_symbolize_keys(v) : v }
                            else
                              value
                            end
        end
      end
    end
  end
end
