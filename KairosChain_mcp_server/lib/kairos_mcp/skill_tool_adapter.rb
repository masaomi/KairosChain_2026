require_relative 'tools/base_tool'
require_relative 'action_log'

module KairosMcp
  # Adapter that wraps a Skill with tool_config as an MCP Tool
  # This allows skills defined in kairos.rb to be exposed as MCP tools
  class SkillToolAdapter < Tools::BaseTool
    def initialize(skill, safety = nil)
      super(safety)
      @skill = skill
      @tool_config = skill.tool_config
    end

    def name
      @tool_config.tool_name || "skill_#{@skill.id}"
    end

    def description
      @tool_config.tool_description || @skill.title || "Skill-based tool: #{@skill.id}"
    end

    def input_schema
      @tool_config.input_schema
    end

    def call(arguments)
      # Record execution to action log
      record_tool_execution(arguments)

      # Execute the tool's execute block
      result = @tool_config.executor&.call(arguments)

      # Format result based on type
      format_result(result)
    rescue StandardError => e
      text_content("Error executing skill tool '#{name}': #{e.message}")
    end

    private

    def record_tool_execution(arguments)
      ActionLog.record(
        action: 'skill_tool_executed',
        skill_id: @skill.id.to_s,
        details: {
          tool_name: name,
          arguments_keys: arguments.keys,
          timestamp: Time.now.iso8601
        }
      )
    end

    def format_result(result)
      case result
      when String
        text_content(result)
      when Hash, Array
        text_content(JSON.pretty_generate(result))
      when NilClass
        text_content("(no output)")
      else
        text_content(result.to_s)
      end
    end
  end
end
