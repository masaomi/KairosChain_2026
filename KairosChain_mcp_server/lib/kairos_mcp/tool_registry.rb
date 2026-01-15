require_relative 'safety'
require_relative 'tools/base_tool'

module KairosMcp
  class ToolRegistry
    def initialize
      @safety = Safety.new
      @tools = {}
      register_tools
    end

    def register_tools
      # Load all tool files
      Dir[File.join(__dir__, 'tools', '*.rb')].each do |file|
        require file
      end

      # Register tools
      register_if_defined('KairosMcp::Tools::HelloWorld')
      register_if_defined('KairosMcp::Tools::SkillsList')
      register_if_defined('KairosMcp::Tools::SkillsGet')
      
      # Future tools (Phase 1+)
      register_if_defined('KairosMcp::Tools::SkillsDslList')
      register_if_defined('KairosMcp::Tools::SkillsDslGet')
      register_if_defined('KairosMcp::Tools::SkillsDslGet')
      register_if_defined('KairosMcp::Tools::SkillsEvolve')
      register_if_defined('KairosMcp::Tools::SkillsRollback')
      
      # Future tools (Phase 2+)
      register_if_defined('KairosMcp::Tools::ChainStatus')
      register_if_defined('KairosMcp::Tools::ChainRecord')
      register_if_defined('KairosMcp::Tools::ChainVerify')
      register_if_defined('KairosMcp::Tools::ChainHistory')
    end

    def register_if_defined(class_name)
      klass = Object.const_get(class_name)
      register(klass.new(@safety))
    rescue NameError
      # Class not defined yet (file might not exist), ignore
    end

    def register(tool)
      @tools[tool.name] = tool
    end

    def set_workspace(roots)
      @safety.set_workspace(roots)
    end

    def list_tools
      @tools.values.map(&:to_schema)
    end

    def call_tool(name, arguments)
      tool = @tools[name]
      unless tool
        raise "Tool not found: #{name}"
      end

      tool.call(arguments)
    end
  end
end
