# frozen_string_literal: true

require_relative 'base'
require 'digest'

module Hestia
  module Chain
    module Integrations
      class MeetingProtocol < Base
        ANCHOR_TYPE = 'meeting'

        def anchor_session(session, async: false)
          validate_session!(session)
          anchor = build_session_anchor(session)
          result = @client.submit(anchor, async: async)
          result.merge(
            session_id: session[:session_id],
            messages_hash: calculate_hash(session[:messages].to_json)
          )
        end

        def anchor_relay(relay_data, async: false)
          validate_relay!(relay_data)
          anchor = build_relay_anchor(relay_data)
          @client.submit(anchor, async: async)
        end

        def anchor_skill_exchange(exchange_data, async: false)
          anchor = build_skill_exchange_anchor(exchange_data)
          @client.submit(anchor, async: async)
        end

        def peer_history(peer_id, limit: 50)
          all = @client.list(anchor_type: ANCHOR_TYPE, limit: limit * 2)
          all.select { |a| a[:participants]&.include?(peer_id) }.first(limit)
        end

        def list_meetings(limit: 100, since: nil)
          @client.list(anchor_type: ANCHOR_TYPE, limit: limit, since: since)
        end

        def meeting_stats
          all = list_meetings(limit: 10_000)
          sessions = all.select { |a| a[:metadata]&.key?(:message_count) }
          relays = all.select { |a| a[:metadata]&.key?(:size_bytes) }
          skill_exchanges = all.select { |a| a[:metadata]&.key?(:skill_name) }
          unique_peers = all.flat_map { |a| a[:participants] || [] }.uniq

          {
            total_anchors: all.size,
            sessions: sessions.size,
            relays: relays.size,
            skill_exchanges: skill_exchanges.size,
            unique_peers: unique_peers.size,
            total_messages: sessions.sum { |s| s.dig(:metadata, :message_count) || 0 },
            total_bytes_relayed: relays.sum { |r| r.dig(:metadata, :size_bytes) || 0 }
          }
        end

        private

        def validate_session!(session)
          required = %i[session_id peer_id messages]
          missing = required.reject { |k| session.key?(k) }
          return if missing.empty?
          raise ArgumentError, "Missing required session fields: #{missing.join(', ')}"
        end

        def validate_relay!(relay_data)
          required = %i[relay_id from to blob_hash]
          missing = required.reject { |k| relay_data.key?(k) }
          return if missing.empty?
          raise ArgumentError, "Missing required relay fields: #{missing.join(', ')}"
        end

        def build_session_anchor(session)
          Core::Anchor.new(
            anchor_type: ANCHOR_TYPE,
            source_id: session[:session_id],
            data_hash: calculate_hash(session.to_json),
            participants: [session[:peer_id]].compact,
            metadata: {
              message_count: session[:messages]&.length || 0,
              started_at: session[:started_at],
              ended_at: session[:ended_at] || Time.now.utc.iso8601
            }.compact
          )
        end

        def build_relay_anchor(relay_data)
          Core::Anchor.new(
            anchor_type: ANCHOR_TYPE,
            source_id: relay_data[:relay_id],
            data_hash: relay_data[:blob_hash],
            participants: [relay_data[:from], relay_data[:to]].compact,
            metadata: {
              relay_type: 'message',
              message_type: relay_data[:message_type],
              size_bytes: relay_data[:size_bytes],
              relayed_at: Time.now.utc.iso8601
            }.compact
          )
        end

        def build_skill_exchange_anchor(exchange_data)
          Core::Anchor.new(
            anchor_type: ANCHOR_TYPE,
            source_id: "skill_#{exchange_data[:skill_name]}_#{Time.now.to_i}",
            data_hash: exchange_data[:skill_hash],
            participants: [exchange_data[:peer_id]].compact,
            metadata: {
              skill_name: exchange_data[:skill_name],
              direction: exchange_data[:direction].to_s,
              exchanged_at: Time.now.utc.iso8601
            }.compact
          )
        end
      end
    end
  end
end
