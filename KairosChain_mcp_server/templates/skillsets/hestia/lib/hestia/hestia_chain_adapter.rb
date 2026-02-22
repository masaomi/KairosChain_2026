# frozen_string_literal: true

require_relative 'chain/core/client'
require_relative 'chain/integrations/meeting_protocol'

module Hestia
  # HestiaChainAdapter implements MMP::ChainAdapter interface
  # using the self-contained Hestia::Chain backend.
  #
  # This replaces MMP::KairosChainAdapter when the hestia SkillSet is active,
  # providing a dedicated anchor chain for inter-agent interactions
  # (separate from KairosChain's internal evolution ledger).
  class HestiaChainAdapter
    include ::MMP::ChainAdapter

    attr_reader :client, :meeting_protocol

    def initialize(config: nil)
      chain_config = config || Chain::Core::Config.new
      @client = Chain::Core::Client.new(config: chain_config)
      @meeting_protocol = Chain::Integrations::MeetingProtocol.new(client: @client)
    end

    # MMP::ChainAdapter interface: record data to HestiaChain
    def record(data)
      entries = data.is_a?(Array) ? data : [data]
      results = entries.map do |entry|
        if entry.is_a?(String)
          @client.anchor(
            anchor_type: 'generic',
            source_id: "log_#{Time.now.to_i}_#{rand(1000)}",
            data: entry
          )
        elsif entry.is_a?(Hash)
          anchor_type = entry[:anchor_type] || entry['anchor_type'] || 'generic'
          source_id = entry[:source_id] || entry['source_id'] || "record_#{Time.now.to_i}"
          @client.anchor(
            anchor_type: anchor_type,
            source_id: source_id,
            data: entry.to_json
          )
        else
          @client.anchor(
            anchor_type: 'generic',
            source_id: "log_#{Time.now.to_i}_#{rand(1000)}",
            data: entry.to_s
          )
        end
      end
      results.size == 1 ? results.first : results
    end

    # MMP::ChainAdapter interface: get history
    def history(filter: {})
      anchor_type = filter[:anchor_type] || filter['anchor_type']
      limit = filter[:limit] || filter['limit'] || 100
      @client.list(limit: limit, anchor_type: anchor_type)
    end

    # MMP::ChainAdapter interface: get raw chain data
    def chain_data
      @client.stats
    end

    # HestiaChain-specific: anchor a meeting session
    def anchor_session(session, async: false)
      @meeting_protocol.anchor_session(session, async: async)
    end

    # HestiaChain-specific: anchor a relay operation
    def anchor_relay(relay_data, async: false)
      @meeting_protocol.anchor_relay(relay_data, async: async)
    end

    # HestiaChain-specific: anchor a skill exchange
    def anchor_skill_exchange(exchange_data, async: false)
      @meeting_protocol.anchor_skill_exchange(exchange_data, async: async)
    end

    # HestiaChain-specific: get meeting stats
    def meeting_stats
      @meeting_protocol.meeting_stats
    end

    # Status
    def status
      @client.status
    end
  end
end
