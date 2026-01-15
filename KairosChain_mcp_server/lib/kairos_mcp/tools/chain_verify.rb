require_relative 'base_tool'
require_relative '../kairos_chain/chain'

module KairosMcp
  module Tools
    class ChainVerify < BaseTool
      def name
        'chain_verify'
      end

      def description
        'Verify the integrity of the entire blockchain.'
      end

      def input_schema
        {
          type: 'object',
          properties: {}
        }
      end

      def call(arguments)
        chain = KairosChain::Chain.new
        is_valid = chain.valid?
        
        if is_valid
          text_content("Blockchain Integrity Verified: OK (Length: #{chain.chain.length})")
        else
          text_content("Blockchain Integrity Check FAILED! Chain may be corrupted.")
        end
      end
    end
  end
end
