# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
require_relative 'protocol_loader'

module KairosMcp
  module Meeting
    # MeetingProtocol defines the semantic actions for agent-to-agent communication.
    # These are "speech acts" - not API commands, but intentional communication.
    #
    # Phase 6: Protocol definitions are now loaded from skill files in knowledge/.
    # This enables dynamic extension of the protocol through skill exchange.
    class MeetingProtocol
      PROTOCOL_VERSION = '1.0.0'

      # Core actions (always available, for backward compatibility)
      CORE_ACTIONS = %w[
        introduce
        goodbye
        error
      ].freeze

      # Legacy action list (for backward compatibility)
      # New code should use @protocol_loader.available_actions
      ACTIONS = %w[
        introduce
        goodbye
        error
        offer_skill
        request_skill
        accept
        decline
        reflect
        skill_content
      ].freeze

      attr_reader :protocol_loader, :supported_extensions

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

      def initialize(identity:, knowledge_root: nil)
        @identity = identity
        @pending_offers = {}  # Track pending skill offers
        @pending_requests = {} # Track pending skill requests
        
        # Phase 6: Initialize protocol loader
        @knowledge_root = knowledge_root || default_knowledge_root
        @protocol_loader = ProtocolLoader.new(knowledge_root: @knowledge_root)
        @supported_extensions = []
        
        # Load protocols from skill files
        load_protocols
      end

      # Load or reload protocols from skill files
      def load_protocols
        result = @protocol_loader.load_all
        @supported_extensions = @protocol_loader.extensions
        result
      rescue StandardError => e
        warn "[MeetingProtocol] Error loading protocols: #{e.message}"
        # Fall back to built-in actions
        { error: e.message, fallback: true }
      end

      # Get all supported actions (from protocol loader + built-in)
      def supported_actions
        if @protocol_loader.available_actions.any?
          @protocol_loader.available_actions
        else
          ACTIONS
        end
      end

      # Check if an action is supported
      def action_supported?(action)
        supported_actions.include?(action)
      end

      # Get core (immutable) actions
      def core_actions
        @protocol_loader.core_actions.any? ? @protocol_loader.core_actions : CORE_ACTIONS
      end

      # Create an introduce message
      # Phase 6: Now includes supported extensions
      def create_introduce
        intro = @identity.introduce
        intro[:extensions] = @supported_extensions
        
        create_message(
          action: 'introduce',
          payload: intro
        )
      end

      # Create a goodbye message (Core Action)
      # @param reason [String] Reason for goodbye
      # @param summary [String, nil] Optional session summary
      def create_goodbye(to:, reason: 'session_complete', summary: nil)
        create_message(
          action: 'goodbye',
          to: to,
          payload: {
            reason: reason,
            summary: summary
          }.compact
        )
      end

      # Create an error message (Core Action)
      # @param to [String] Recipient instance_id
      # @param error_code [String] Error code
      # @param message [String] Error message
      # @param recoverable [Boolean] Whether error is recoverable
      # @param in_reply_to [String, nil] Message being responded to
      def create_error(to:, error_code:, message:, recoverable: true, in_reply_to: nil, details: nil)
        create_message(
          action: 'error',
          to: to,
          in_reply_to: in_reply_to,
          payload: {
            error_code: error_code,
            message: message,
            recoverable: recoverable,
            details: details
          }.compact
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
        
        # Validate message structure (basic validation)
        validate_message_structure!(msg_data)

        action = msg_data[:action]
        
        # Phase 6: Check if action is supported
        unless action_supported?(action)
          return {
            status: 'error',
            action: 'error',
            error: "Unsupported action: #{action}",
            suggested_response: create_error(
              to: msg_data[:from],
              error_code: 'unsupported_action',
              message: "Action '#{action}' is not supported by this agent",
              recoverable: true,
              in_reply_to: msg_data[:id],
              details: {
                unsupported_action: action,
                supported_actions: supported_actions
              }
            )
          }
        end
        
        # Process based on action type
        case action
        # Core Actions
        when 'introduce'
          process_introduce(msg_data)
        when 'goodbye'
          process_goodbye(msg_data)
        when 'error'
          process_error(msg_data)
        # Skill Exchange Extension
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
          # This shouldn't happen if action_supported? works correctly
          { status: 'error', error: "Unknown action: #{action}" }
        end
      end

      private

      def default_knowledge_root
        # Find knowledge root relative to this file
        lib_dir = File.dirname(File.dirname(File.dirname(__FILE__)))
        File.join(File.dirname(lib_dir), 'knowledge')
      end

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

      # Basic message structure validation (doesn't check action validity)
      def validate_message_structure!(msg_data)
        required_fields = %i[id action from timestamp]
        missing = required_fields.select { |f| msg_data[f].nil? }
        
        raise ArgumentError, "Missing required fields: #{missing.join(', ')}" unless missing.empty?
      end

      # Legacy validation (for backward compatibility)
      def validate_message!(msg_data)
        validate_message_structure!(msg_data)
        raise ArgumentError, "Unknown action: #{msg_data[:action]}" unless action_supported?(msg_data[:action])
      end

      def process_introduce(msg_data)
        payload = msg_data[:payload] || {}
        peer_extensions = payload[:extensions] || []
        
        # Calculate common extensions
        common_extensions = @supported_extensions & peer_extensions
        
        {
          status: 'received',
          action: 'introduce',
          from: msg_data[:from],
          peer_identity: payload,
          peer_extensions: peer_extensions,
          common_extensions: common_extensions,
          suggested_response: create_introduce
        }
      end

      def process_goodbye(msg_data)
        payload = msg_data[:payload] || {}
        
        {
          status: 'received',
          action: 'goodbye',
          from: msg_data[:from],
          reason: payload[:reason],
          summary: payload[:summary],
          session_complete: true
        }
      end

      def process_error(msg_data)
        payload = msg_data[:payload] || {}
        
        {
          status: 'received',
          action: 'error',
          from: msg_data[:from],
          error_code: payload[:error_code],
          message: payload[:message],
          recoverable: payload[:recoverable],
          details: payload[:details],
          in_reply_to: msg_data[:in_reply_to]
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
