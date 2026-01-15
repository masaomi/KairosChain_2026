require_relative 'base_tool'
require_relative '../kairos_chain/chain'

module KairosMcp
  module Tools
    class ChainHistory < BaseTool
      def name
        'chain_history'
      end

      def description
        'Get block history from the blockchain.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            limit: {
              type: 'integer',
              description: 'Number of blocks to retrieve (default: 10)'
            }
          }
        }
      end

      def call(arguments)
        limit = arguments['limit'] || 10
        chain = KairosChain::Chain.new
        
        blocks = chain.chain.last(limit).reverse
        
        text_content(JSON.pretty_generate(blocks.map(&:to_h)))
      end
    end
  end
end
