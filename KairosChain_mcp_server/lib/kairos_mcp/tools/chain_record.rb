require_relative 'base_tool'
require_relative '../kairos_chain/chain'

module KairosMcp
  module Tools
    class ChainRecord < BaseTool
      def name
        'chain_record'
      end

      def description
        'Record data to the KairosChain blockchain. Should primarily be used for Skill Transitions, but can record generic logs.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            logs: {
              type: 'array',
              items: { type: 'string' },
              description: 'Array of log strings to record in the block'
            }
          },
          required: ['logs']
        }
      end

      def call(arguments)
        logs = arguments['logs']
        return text_content("Error: logs array is required") unless logs && logs.is_a?(Array) && !logs.empty?

        chain = KairosChain::Chain.new
        new_block = chain.add_block(logs)
        
        text_content("Block ##{new_block.index} recorded successfully.\nHash: #{new_block.hash}")
      end
    end
  end
end
