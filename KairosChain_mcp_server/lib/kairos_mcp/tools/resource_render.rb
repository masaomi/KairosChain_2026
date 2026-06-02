# frozen_string_literal: true

require 'open3'
require 'timeout'
require_relative 'base_tool'
require_relative '../anthropic_skill_parser'

module KairosMcp
  module Tools
    class ResourceRender < BaseTool
      RENDER_TIMEOUT = 30

      def name
        'resource_render'
      end

      def description
        'Execute a render script from a knowledge entry to generate an HTML asset. ' \
        'Scripts live in knowledge/{name}/scripts/ and output HTML to assets/. ' \
        'Data is passed via stdin as JSON. Convention: scripts named render_*.rb.'
      end

      def category
        :resource
      end

      def usecase_tags
        %w[render html visualize dashboard asset generate]
      end

      def examples
        [
          {
            title: 'Generate review dashboard',
            code: 'resource_render(knowledge: "multi_llm_review_workflow", ' \
                  'script: "render_dashboard.rb", data: "{...}", open: true)'
          },
          {
            title: 'Generate with custom output name',
            code: 'resource_render(knowledge: "multi_llm_review_workflow", ' \
                  'script: "render_dashboard.rb", data: "{...}", output: "round2.html")'
          }
        ]
      end

      def related_tools
        %w[resource_list resource_read knowledge_get]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            knowledge: {
              type: 'string',
              description: 'L1 knowledge entry name (e.g., "multi_llm_review_workflow")'
            },
            script: {
              type: 'string',
              description: 'Script filename in the knowledge scripts/ directory (e.g., "render_dashboard.rb")'
            },
            data: {
              type: 'string',
              description: 'JSON data to pass to the script via stdin'
            },
            output: {
              type: 'string',
              description: 'Output filename in assets/ (default: derived from script name, e.g., render_dashboard.rb -> dashboard.html)'
            },
            open: {
              type: 'boolean',
              description: 'Open the generated HTML in the default browser (default: false)'
            }
          },
          required: %w[knowledge script data]
        }
      end

      def call(arguments)
        knowledge_name = arguments['knowledge']
        script_name = arguments['script']
        data = arguments['data']
        output_name = arguments['output']
        open_after = arguments['open'] || false

        return text_content("Error: knowledge is required") unless knowledge_name && !knowledge_name.empty?
        return text_content("Error: script is required") unless script_name && !script_name.empty?
        return text_content("Error: data is required") unless data && !data.empty?

        # Validate JSON
        begin
          JSON.parse(data)
        rescue JSON::ParserError => e
          return text_content("Error: invalid JSON data — #{e.message}")
        end

        # Resolve knowledge directory
        knowledge_dir = File.join(KairosMcp.knowledge_dir(user_context: @safety&.current_user), knowledge_name)
        unless File.directory?(knowledge_dir)
          return text_content("Error: knowledge '#{knowledge_name}' not found")
        end

        # Security: normalize script name to prevent path traversal
        safe_script = File.basename(script_name)
        script_path = File.join(knowledge_dir, 'scripts', safe_script)
        unless File.exist?(script_path)
          return text_content("Error: script '#{safe_script}' not found in #{knowledge_name}/scripts/")
        end

        # Derive output filename
        if output_name
          safe_output = File.basename(output_name)
        else
          safe_output = safe_script
                          .sub(/\Arender_/, '')
                          .sub(/\.rb\z/, '.html')
        end

        # Ensure assets/ directory exists
        assets_dir = File.join(knowledge_dir, 'assets')
        FileUtils.mkdir_p(assets_dir)

        # Execute script with data on stdin
        stdout, stderr, status = execute_script(script_path, data, knowledge_dir)

        unless status.success?
          error_msg = "Error: script exited with code #{status.exitstatus}"
          error_msg += "\n\nstderr:\n```\n#{stderr}\n```" unless stderr.empty?
          return text_content(error_msg)
        end

        if stdout.nil? || stdout.empty?
          return text_content("Error: script produced no output")
        end

        # Write output to assets/
        output_path = File.join(assets_dir, safe_output)
        AnthropicSkillParser.atomic_write(output_path, stdout)

        # Open in browser if requested
        if open_after
          system('open', output_path)
        end

        uri = "knowledge://#{knowledge_name}/assets/#{safe_output}"
        build_success_response(uri, output_path, stdout.bytesize, open_after)
      end

      private

      def execute_script(script_path, data, working_dir)
        Timeout.timeout(RENDER_TIMEOUT) do
          Open3.capture3(
            'ruby', script_path,
            stdin_data: data,
            chdir: working_dir
          )
        end
      rescue Timeout::Error
        ["", "Script execution timed out after #{RENDER_TIMEOUT}s", OpenStruct.new(success?: false, exitstatus: 124)]
      end

      def build_success_response(uri, path, size, opened)
        output = "## Resource Rendered\n\n"
        output += "| Property | Value |\n"
        output += "|----------|-------|\n"
        output += "| **URI** | `#{uri}` |\n"
        output += "| **Path** | `#{path}` |\n"
        output += "| **Size** | #{format_size(size)} |\n"
        output += "| **Opened** | #{opened ? 'Yes' : 'No'} |\n\n"
        output += "Use `resource_read(uri: \"#{uri}\")` to read the generated content.\n"
        output += "Use `open #{path}` to view in browser." unless opened
        text_content(output)
      end

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
