require_relative 'base_tool'
require_relative '../kairos_chain/chain'
require 'json'

module KairosMcp
  module Tools
    class ChainHistory < BaseTool
      def name
        'chain_history'
      end

      def description
        'Get block history from the blockchain. Shows skill transitions, knowledge updates, and state commits.'
      end

      def category
        :chain
      end

      def usecase_tags
        %w[history blocks blockchain audit trail log]
      end

      def examples
        [
          {
            title: 'Get recent history',
            code: 'chain_history(limit: 10)'
          },
          {
            title: 'Filter by type',
            code: 'chain_history(type: "skill_transition")'
          },
          {
            title: 'Get raw JSON',
            code: 'chain_history(format: "json")'
          }
        ]
      end

      def related_tools
        %w[chain_status chain_verify state_history]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            limit: {
              type: 'integer',
              description: 'Number of blocks to retrieve (default: 10)'
            },
            format: {
              type: 'string',
              description: 'Output format: "formatted" (human-readable, default) or "json" (raw)',
              enum: %w[formatted json]
            },
            type: {
              type: 'string',
              description: 'Filter by block type: "all" (default), "state_commit", "skill_transition", "knowledge_update"',
              enum: %w[all state_commit skill_transition knowledge_update]
            }
          }
        }
      end

      def call(arguments)
        limit = arguments['limit'] || 10
        format = arguments['format'] || 'formatted'
        type_filter = arguments['type'] || 'all'
        
        chain = KairosChain::Chain.new
        blocks = chain.chain.last(limit + 10).reverse  # Get extra for filtering
        
        # Filter by type if specified
        if type_filter != 'all'
          blocks = blocks.select { |b| block_type(b) == type_filter }
        end
        
        blocks = blocks.first(limit)
        
        if format == 'json'
          text_content(JSON.pretty_generate(blocks.map(&:to_h)))
        else
          format_blocks(blocks)
        end
      end

      private

      def block_type(block)
        data = parse_block_data(block)
        return 'genesis' if block.index == 0
        
        data['type'] || data[:type] || 'unknown'
      end

      def parse_block_data(block)
        data_array = block.data
        return {} if data_array.empty?
        
        first_data = data_array.first
        if first_data.is_a?(String)
          JSON.parse(first_data) rescue {}
        else
          first_data
        end
      end

      def format_blocks(blocks)
        output = "Blockchain History\n"
        output += "=" * 50 + "\n\n"

        if blocks.empty?
          output += "(No blocks found)\n"
          return text_content(output)
        end

        blocks.each do |block|
          output += format_single_block(block)
          output += "\n" + "-" * 40 + "\n\n"
        end

        output += "Total: #{blocks.size} blocks shown\n"
        text_content(output)
      end

      def format_single_block(block)
        data = parse_block_data(block)
        type = block_type(block)
        
        output = "Block ##{block.index}"
        output += " (#{type})\n"
        output += "  Hash: #{block.hash[0..15]}...\n"
        output += "  Time: #{block.timestamp}\n"
        
        case type
        when 'genesis'
          output += "  Data: Genesis Block\n"
        when 'state_commit'
          output += format_state_commit(data)
        when 'skill_transition'
          output += format_skill_transition(data)
        when 'knowledge_update'
          output += format_knowledge_update(data)
        else
          output += "  Data: #{data.to_s[0..100]}...\n" if data.any?
        end
        
        output
      end

      def format_state_commit(data)
        output = ""
        output += "  Commit Type: #{data['commit_type'] || data[:commit_type]}\n"
        output += "  Actor: #{data['actor'] || data[:actor]}\n"
        output += "  Reason: #{data['reason'] || data[:reason]}\n"
        
        summary = data['summary'] || data[:summary] || {}
        if summary.any?
          output += "  Summary:\n"
          output += "    L0 Changed: #{summary['L0_changed'] || summary[:L0_changed] || 'No'}\n"
          
          l1_changes = []
          l1_changes << "+#{summary['L1_added'] || summary[:L1_added]}" if (summary['L1_added'] || summary[:L1_added]).to_i > 0
          l1_changes << "~#{summary['L1_modified'] || summary[:L1_modified]}" if (summary['L1_modified'] || summary[:L1_modified]).to_i > 0
          l1_changes << "-#{summary['L1_deleted'] || summary[:L1_deleted]}" if (summary['L1_deleted'] || summary[:L1_deleted]).to_i > 0
          output += "    L1: #{l1_changes.join(', ')}\n" if l1_changes.any?
          
          promotions = summary['promotions'] || summary[:promotions] || 0
          output += "    Promotions: #{promotions}\n" if promotions.to_i > 0
        end
        
        snapshot_ref = data['snapshot_ref'] || data[:snapshot_ref]
        output += "  Snapshot: #{snapshot_ref}\n" if snapshot_ref
        
        output
      end

      def format_skill_transition(data)
        output = ""
        output += "  Skill: #{data['skill_id'] || data[:skill_id]}\n"
        
        prev_hash = data['prev_ast_hash'] || data[:prev_ast_hash]
        next_hash = data['next_ast_hash'] || data[:next_ast_hash]
        output += "  Prev Hash: #{prev_hash[0..15]}...\n" if prev_hash
        output += "  Next Hash: #{next_hash[0..15]}...\n" if next_hash
        
        reason_ref = data['reason_ref'] || data[:reason_ref]
        output += "  Reason: #{reason_ref}\n" if reason_ref
        
        output
      end

      def format_knowledge_update(data)
        output = ""
        output += "  Layer: #{data['layer'] || data[:layer]}\n"
        output += "  Knowledge: #{data['knowledge_id'] || data[:knowledge_id]}\n"
        output += "  Action: #{data['action'] || data[:action]}\n"
        
        prev_hash = data['prev_hash'] || data[:prev_hash]
        next_hash = data['next_hash'] || data[:next_hash]
        output += "  Prev Hash: #{prev_hash[0..15]}...\n" if prev_hash
        output += "  Next Hash: #{next_hash[0..15]}...\n" if next_hash
        
        reason = data['reason'] || data[:reason]
        output += "  Reason: #{reason}\n" if reason
        
        output
      end
    end
  end
end
