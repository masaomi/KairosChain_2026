# frozen_string_literal: true

module MMP
  # Abstract interface for blockchain recording.
  # Implementations wrap different chain backends (KairosChain, HestiaChain, etc.)
  module ChainAdapter
    def record(data)
      raise NotImplementedError, "#{self.class}#record not implemented"
    end

    def history(filter: {})
      raise NotImplementedError, "#{self.class}#history not implemented"
    end

    def chain_data
      raise NotImplementedError, "#{self.class}#chain_data not implemented"
    end
  end

  # Default adapter using KairosChain's private blockchain
  class KairosChainAdapter
    include ChainAdapter

    def initialize
      require 'kairos_mcp/kairos_chain/chain'
      @chain = KairosMcp::KairosChain::Chain.new
    end

    def record(data)
      @chain.add_block(Array(data).map { |d| d.is_a?(String) ? d : d.to_json })
    end

    def history(filter: {})
      @chain.chain.flat_map { |block| block.data }
    end

    def chain_data
      @chain.chain
    end
  end

  # Null adapter for when no blockchain is needed (L2 SkillSets)
  class NullChainAdapter
    include ChainAdapter

    def record(data)
      { status: 'skipped', reason: 'null_adapter' }
    end

    def history(filter: {})
      []
    end

    def chain_data
      []
    end
  end
end
