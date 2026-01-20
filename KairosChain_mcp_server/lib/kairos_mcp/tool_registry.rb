require_relative 'safety'
require_relative 'tools/base_tool'
require_relative 'skills_config'

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
      
      # L0-A: skills/kairos.md (read-only)
      register_if_defined('KairosMcp::Tools::SkillsList')
      register_if_defined('KairosMcp::Tools::SkillsGet')
      
      # L0-B: skills/kairos.rb (self-modifying with full blockchain record)
      register_if_defined('KairosMcp::Tools::SkillsDslList')
      register_if_defined('KairosMcp::Tools::SkillsDslGet')
      register_if_defined('KairosMcp::Tools::SkillsEvolve')
      register_if_defined('KairosMcp::Tools::SkillsRollback')
      
      # Resource tools (unified access to L0/L1/L2 resources)
      register_if_defined('KairosMcp::Tools::ResourceList')
      register_if_defined('KairosMcp::Tools::ResourceRead')

      # L1: knowledge/ (Anthropic skills format with hash-only blockchain record)
      register_if_defined('KairosMcp::Tools::KnowledgeList')
      register_if_defined('KairosMcp::Tools::KnowledgeGet')
      register_if_defined('KairosMcp::Tools::KnowledgeUpdate')
      
      # L2: context/ (Anthropic skills format without blockchain record)
      register_if_defined('KairosMcp::Tools::ContextSave')
      register_if_defined('KairosMcp::Tools::ContextCreateSubdir')
      
      # Chain tools
      register_if_defined('KairosMcp::Tools::ChainStatus')
      register_if_defined('KairosMcp::Tools::ChainRecord')
      register_if_defined('KairosMcp::Tools::ChainVerify')
      register_if_defined('KairosMcp::Tools::ChainHistory')

      # Skill-based tools (from kairos.rb with tool block)
      register_skill_tools if skill_tools_enabled?
    end

    # Register tools defined in kairos.rb via tool block
    def register_skill_tools
      require_relative 'skill_tool_adapter'
      require_relative 'kairos'

      Kairos.skills.each do |skill|
        next unless skill.has_tool?  # Only skills with tool block and executor
        adapter = SkillToolAdapter.new(skill, @safety)
        register(adapter)
      end
    end

    def skill_tools_enabled?
      SkillsConfig.load['skill_tools_enabled'] == true
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
