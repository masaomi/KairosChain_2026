# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module LlmClient
      # Converts MCP tool schemas to LLM provider formats.
      module SchemaConverter
        module_function

        # MCP → Anthropic: rename inputSchema → input_schema
        def to_anthropic(mcp_schema)
          {
            name: mcp_schema[:name],
            description: truncate_description(mcp_schema[:description], 4096),
            input_schema: mcp_schema[:inputSchema] || { type: 'object', properties: {} }
          }
        end

        # MCP → OpenAI: wrap in function envelope, normalize JSON Schema
        def to_openai(mcp_schema)
          params = normalize_for_openai(mcp_schema[:inputSchema] || { type: 'object', properties: {} })
          {
            type: 'function',
            function: {
              name: mcp_schema[:name],
              description: truncate_description(mcp_schema[:description], 1024),
              parameters: params
            }
          }
        end

        # Batch convert with error isolation per tool
        def convert_batch(mcp_schemas, target)
          converter = target == :openai ? method(:to_openai) : method(:to_anthropic)
          results = []
          errors = []

          mcp_schemas.each do |schema|
            results << converter.call(schema)
          rescue StandardError => e
            errors << { tool: schema[:name], error: e.message }
          end

          { schemas: results, errors: errors }
        end

        # Normalize JSON Schema for OpenAI strict mode compatibility.
        # When strict: true, OpenAI requires additionalProperties: false and
        # all properties listed in required on every object.
        def normalize_for_openai(schema)
          return schema unless schema.is_a?(Hash)

          normalized = schema.dup

          if normalized['type'] == 'object' || normalized[:type] == 'object'
            # OpenAI requires explicit additionalProperties: false
            key = normalized.key?(:type) ? :additionalProperties : 'additionalProperties'
            normalized[key] = false unless normalized.key?(key) || normalized.key?(:additionalProperties) || normalized.key?('additionalProperties')

            # OpenAI strict mode requires all properties in required array
            props = normalized[:properties] || normalized['properties']
            unless normalized.key?(:required) || normalized.key?('required')
              if props.is_a?(Hash) && !props.empty?
                req_key = normalized.key?(:type) ? :required : 'required'
                normalized[req_key] = props.keys.map(&:to_s)
              end
            end
          end

          # Recursively normalize nested properties
          props_key = normalized.key?(:properties) ? :properties : 'properties'
          if normalized[props_key].is_a?(Hash)
            normalized[props_key] = normalized[props_key].transform_values { |v| normalize_for_openai(v) }
          end

          # Normalize items in arrays
          items_key = normalized.key?(:items) ? :items : 'items'
          if normalized[items_key].is_a?(Hash)
            normalized[items_key] = normalize_for_openai(normalized[items_key])
          end

          normalized
        end

        def truncate_description(desc, max_len)
          return '' if desc.nil?
          desc.length > max_len ? "#{desc[0...max_len - 3]}..." : desc
        end
      end
    end
  end
end
