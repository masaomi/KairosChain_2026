require_relative 'base_tool'
require_relative '../kairos_chain/chain'
require 'json'

module KairosMcp
  module Tools
    class FormalizationHistory < BaseTool
      def name
        'formalization_history'
      end

      def description
        'View accumulated formalization decisions from the blockchain. Filter by skill_id or formalization_category to find patterns.'
      end

      def category
        :chain
      end

      def usecase_tags
        %w[formalization history decisions patterns audit provenance]
      end

      def examples
        [
          {
            title: 'View all formalization decisions',
            code: 'formalization_history()'
          },
          {
            title: 'Filter by skill',
            code: 'formalization_history(skill_id: "core_safety")'
          },
          {
            title: 'Filter by category',
            code: 'formalization_history(category: "invariant")'
          }
        ]
      end

      def related_tools
        %w[formalization_record skills_dsl_get chain_history]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            skill_id: {
              type: 'string',
              description: 'Filter by skill ID (optional)'
            },
            category: {
              type: 'string',
              description: 'Filter by formalization category: invariant, rule, guideline, policy, philosophy (optional)'
            },
            limit: {
              type: 'integer',
              description: 'Maximum number of decisions to return (default: 20)'
            }
          }
        }
      end

      def call(arguments)
        skill_id_filter = arguments['skill_id']
        category_filter = arguments['category']
        limit = (arguments['limit'] || 20).to_i

        chain = KairosChain::Chain.new
        decisions = []

        # Scan all blocks for formalization decisions
        chain.chain.each do |block|
          next if block.index == 0 # Skip genesis

          block.data.each do |data_item|
            parsed = parse_decision(data_item)
            next unless parsed

            # Apply filters
            next if skill_id_filter && parsed[:skill_id] != skill_id_filter
            next if category_filter && parsed[:formalization_category].to_s != category_filter

            decisions << parsed.merge(block_index: block.index)
          end
        end

        # Sort by timestamp (newest first) and limit
        decisions.sort_by! { |d| d[:timestamp] || '' }.reverse!
        decisions = decisions.first(limit)

        if decisions.empty?
          filters = []
          filters << "skill_id=#{skill_id_filter}" if skill_id_filter
          filters << "category=#{category_filter}" if category_filter
          filter_msg = filters.empty? ? "" : " (filters: #{filters.join(', ')})"
          return text_content("No formalization decisions found#{filter_msg}.")
        end

        output = "## Formalization Decisions (#{decisions.size})\n\n"

        decisions.each_with_index do |d, i|
          output += "### #{i + 1}. #{d[:skill_id]} — #{d[:result]}\n"
          output += "- **Block**: ##{d[:block_index]}\n"
          output += "- **Version**: #{d[:skill_version]}\n"
          output += "- **Category**: #{d[:formalization_category]}\n"
          output += "- **Source**: #{truncate(d[:source_text].to_s, 80)}\n"
          output += "- **Rationale**: #{d[:rationale]}\n"
          output += "- **Decided by**: #{d[:decided_by]}\n"
          output += "- **Timestamp**: #{d[:timestamp]}\n"
          output += "\n"
        end

        # Summary statistics
        formalized_count = decisions.count { |d| d[:result].to_s == 'formalized' }
        not_formalized_count = decisions.count { |d| d[:result].to_s == 'not_formalized' }
        output += "---\n"
        output += "**Summary**: #{formalized_count} formalized, #{not_formalized_count} not formalized\n"

        text_content(output)
      end

      private

      def parse_decision(data_item)
        parsed = JSON.parse(data_item, symbolize_names: true)
        return nil unless parsed[:type]&.to_s == 'formalization_decision'
        parsed
      rescue JSON::ParserError
        nil
      end

      def truncate(str, max)
        str.length > max ? "#{str[0, max]}..." : str
      end
    end
  end
end
