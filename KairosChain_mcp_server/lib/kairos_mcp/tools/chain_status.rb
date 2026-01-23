require_relative 'base_tool'
require_relative '../kairos_chain/chain'
require_relative '../skills_config'

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
        
        # Build storage info
        backend = SkillsConfig.storage_backend
        storage_info = { backend: backend }
        
        if backend == 'sqlite'
          sqlite_config = SkillsConfig.sqlite_config
          storage_info[:sqlite_path] = sqlite_config['path']
          storage_info[:wal_mode] = sqlite_config['wal_mode']
        end
        
        status = {
          valid: chain.valid?,
          length: chain.chain.length,
          storage: storage_info,
          latest_block: chain.latest_block.to_h
        }
        
        text_content(JSON.pretty_generate(status))
      end
    end
  end
end
