# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../resource_registry'

module KairosMcp
  module Tools
    # ResourceRead: Read a resource by URI
    #
    # Fetches content from any layer using the unified URI scheme.
    # Use resource_list to discover available URIs.
    #
    class ResourceRead < BaseTool
      def name
        'resource_read'
      end

      def description
        'Read a resource by URI. Use resource_list to discover available URIs. ' \
        'Supports L0 (l0://), L1 knowledge (knowledge://), and L2 context (context://) resources.'
      end

      def input_schema
        {
          type: 'object',
          properties: {
            uri: {
              type: 'string',
              description: 'Resource URI. Examples: ' \
                          '"l0://kairos.md", "knowledge://example_knowledge", ' \
                          '"knowledge://example_knowledge/scripts/test.sh", ' \
                          '"context://session_id/context_name"'
            }
          },
          required: ['uri']
        }
      end

      def call(arguments)
        uri = arguments['uri']
        return text_content('Error: uri is required') unless uri && !uri.empty?

        registry = ResourceRegistry.new
        resource = registry.read(uri)

        if resource.nil?
          return text_content(build_not_found_response(uri))
        end

        text_content(build_response(resource))
      end

      private

      def build_not_found_response(uri)
        output = "## Resource Not Found\n\n"
        output += "**URI:** `#{uri}`\n\n"
        output += "The requested resource could not be found.\n\n"
        output += "### Troubleshooting\n\n"
        output += "1. Use `resource_list` to see available resources\n"
        output += "2. Check the URI format:\n"
        output += "   - L0: `l0://kairos.md` or `l0://kairos.rb`\n"
        output += "   - L1: `knowledge://{name}` or `knowledge://{name}/scripts/{file}`\n"
        output += "   - L2: `context://{session}/{name}` or `context://{session}/{name}/scripts/{file}`\n"
        output
      end

      def build_response(resource)
        output = "## Resource: #{resource[:uri]}\n\n"

        # Metadata section
        output += "### Metadata\n\n"
        output += "| Property | Value |\n"
        output += "|----------|-------|\n"
        output += "| **Layer** | #{resource[:layer]} |\n"
        output += "| **MIME Type** | #{resource[:mime_type]} |\n"
        output += "| **Size** | #{format_size(resource[:size])} |\n"
        output += "| **Modified** | #{resource[:modified_at]} |\n"
        output += "| **Path** | `#{resource[:path]}` |\n"

        if resource[:executable]
          output += "| **Executable** | Yes |\n"
        end

        if resource[:binary]
          output += "| **Binary** | Yes |\n"
        end

        output += "\n"

        # Content section
        output += "### Content\n\n"

        if resource[:binary]
          output += "*Binary file - content not displayed*\n"
        else
          # Determine language for syntax highlighting
          lang = syntax_lang(resource[:mime_type], resource[:uri])
          output += "```#{lang}\n"
          output += resource[:content]
          output += "\n```\n"
        end

        # Execution hint for scripts
        if resource[:executable]
          output += "\n### Execution\n\n"
          output += "This file is executable. To run it:\n\n"
          output += "```bash\n"
          output += "#{resource[:path]}\n"
          output += "```\n"
        end

        output
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

      def syntax_lang(mime_type, uri)
        case mime_type
        when 'text/markdown' then 'markdown'
        when 'text/x-ruby' then 'ruby'
        when 'text/x-python' then 'python'
        when 'application/x-sh' then 'bash'
        when 'text/javascript' then 'javascript'
        when 'text/typescript' then 'typescript'
        when 'application/json' then 'json'
        when 'application/yaml' then 'yaml'
        when 'text/html' then 'html'
        when 'text/css' then 'css'
        else
          # Fallback: try to guess from extension
          ext = File.extname(uri).downcase
          case ext
          when '.md' then 'markdown'
          when '.rb' then 'ruby'
          when '.py' then 'python'
          when '.sh', '.bash' then 'bash'
          when '.js' then 'javascript'
          when '.ts' then 'typescript'
          when '.json' then 'json'
          when '.yaml', '.yml' then 'yaml'
          else ''
          end
        end
      end
    end
  end
end
