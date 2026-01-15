require_relative 'base_tool'
require_relative '../kairos_chain/chain'

module KairosMcp
  module Tools
    class ChainStatus < BaseTool
      def name
        'chain_status'
      end

      def description
        'Get the current status of the KairosChain blockchain.'
      end

      def input_schema
        {
          type: 'object',
          properties: {}
        }
      end

      def call(arguments)
        chain = KairosChain::Chain.new
        
        status = {
          valid: chain.valid?,
          length: chain.chain.length,
          latest_block: chain.latest_block.to_h
        }
        
        text_content(JSON.pretty_generate(status))
      end
    end
  end
end
