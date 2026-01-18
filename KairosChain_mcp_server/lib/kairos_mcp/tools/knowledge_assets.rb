# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../knowledge_provider'

module KairosMcp
  module Tools
    class KnowledgeAssets < BaseTool
      def name
        'knowledge_assets'
      end

      def description
        'List all assets in a L1 knowledge skill. Assets include templates, images, CSS, and other resource files.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The knowledge skill name'
            }
          },
          required: ['name']
        }
      end

      def call(arguments)
        name = arguments['name']
        return text_content("Error: name is required") unless name && !name.empty?

        provider = KnowledgeProvider.new
        skill = provider.get(name)

        if skill.nil?
          return text_content("Knowledge '#{name}' not found")
        end

        assets = provider.list_assets(name)

        if assets.empty?
          return text_content("No assets found in '#{name}'. Assets directory: #{skill.assets_path}")
        end

        output = "## Assets in '#{name}'\n\n"
        output += "| Path | Extension | Size |\n"
        output += "|------|-----------|------|\n"

        assets.each do |asset|
          ext = asset[:extension].empty? ? '-' : asset[:extension]
          size = format_size(asset[:size])
          output += "| #{asset[:relative_path]} | #{ext} | #{size} |\n"
        end

        output += "\n**Assets path:** `#{skill.assets_path}`"
        text_content(output)
      end

      private

      def format_size(bytes)
        if bytes < 1024
          "#{bytes} B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(1)} KB"
        else
          "#{(bytes / (1024.0 * 1024)).round(1)} MB"
        end
      end
    end
  end
end
