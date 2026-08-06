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

      def category
        :chain
      end

      def usecase_tags
        %w[verify integrity check blockchain validate]
      end

      def examples
        [
          {
            title: 'Verify blockchain integrity',
            code: 'chain_verify()'
          }
        ]
      end

      def related_tools
        %w[chain_status chain_history]
      end

      def input_schema
        {
          type: 'object',
          properties: {}
        }
      end

      def call(arguments)
        chain = KairosChain::Chain.new

        # Three outcomes, not two: a ledger that does not exist yet is a fresh
        # install, not a corrupted one.
        case chain.load_state
        when :readable
          text_content("Blockchain Integrity Verified: OK (Length: #{chain.chain.length})")
        when :absent
          text_content('Blockchain not created yet (state: absent). Nothing to verify.')
        else
          text_content("Blockchain Integrity Check FAILED! (state: #{chain.load_state})")
        end
      end
    end
  end
end
