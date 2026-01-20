# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../resource_registry'

module KairosMcp
  module Tools
    # ResourceList: List available resources across all layers (L0/L1/L2)
    #
    # Provides unified access to discover resources via URI-based system.
    # Use resource_read to fetch content of discovered resources.
    #
    class ResourceList < BaseTool
      def name
        'resource_list'
      end

      def description
        'List available resources across all layers (L0/L1/L2). ' \
        'Returns URIs that can be read with resource_read. ' \
        'Resources include skills (L0), knowledge files/scripts/assets (L1), ' \
        'and context files/scripts/assets (L2).'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            filter: {
              type: 'string',
              description: 'Filter resources: "l0", "knowledge", "context", ' \
                          'or a specific name like "example_knowledge" or "session_xxx/context_name"'
            },
            type: {
              type: 'string',
              enum: %w[all md scripts assets references],
              description: 'Filter by resource type. Default: "all"'
            },
            layer: {
              type: 'string',
              enum: %w[all l0 l1 l2],
              description: 'Filter by layer. Default: "all"'
            }
          }
        }
      end

      def call(arguments)
        filter = arguments['filter']
        type = arguments['type'] || 'all'
        layer = arguments['layer'] || 'all'

        registry = ResourceRegistry.new
        resources = registry.list(filter: filter, type: type, layer: layer)

        if resources.empty?
          return text_content(build_empty_response(filter, type, layer))
        end

        text_content(build_response(resources, filter, type, layer))
      end

      private

      def build_empty_response(filter, type, layer)
        filters = []
        filters << "filter=#{filter}" if filter
        filters << "type=#{type}" if type != 'all'
        filters << "layer=#{layer}" if layer != 'all'

        filter_str = filters.empty? ? '' : " (#{filters.join(', ')})"
        "No resources found#{filter_str}."
      end

      def build_response(resources, filter, type, layer)
        output = "## Resources\n\n"

        # Group by layer
        grouped = resources.group_by { |r| r[:layer] }

        %w[L0 L1 L2].each do |layer_name|
          layer_resources = grouped[layer_name]
          next unless layer_resources&.any?

          output += "### #{layer_name} (#{layer_label(layer_name)})\n\n"
          output += "| URI | Name | Type | Size |\n"
          output += "|-----|------|------|------|\n"

          layer_resources.each do |r|
            size = format_size(r[:size])
            output += "| `#{r[:uri]}` | #{r[:name]} | #{r[:type]} | #{size} |\n"
          end

          output += "\n"
        end

        # Summary
        output += "---\n"
        output += "**Total:** #{resources.size} resources"

        filters = []
        filters << "filter=#{filter}" if filter
        filters << "type=#{type}" if type != 'all'
        filters << "layer=#{layer}" if layer != 'all'
        output += " (#{filters.join(', ')})" unless filters.empty?

        output += "\n\n**Usage:** Use `resource_read` with any URI above to get the content."

        output
      end

      def layer_label(layer)
        case layer
        when 'L0' then 'Skills'
        when 'L1' then 'Knowledge'
        when 'L2' then 'Context'
        else layer
        end
      end

      def format_size(bytes)
        return '0 B' if bytes.nil? || bytes.zero?

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
