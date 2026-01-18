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
      
      # L0-A: skills/kairos.md (read-only)
      register_if_defined('KairosMcp::Tools::SkillsList')
      register_if_defined('KairosMcp::Tools::SkillsGet')
      
      # L0-B: skills/kairos.rb (self-modifying with full blockchain record)
      register_if_defined('KairosMcp::Tools::SkillsDslList')
      register_if_defined('KairosMcp::Tools::SkillsDslGet')
      register_if_defined('KairosMcp::Tools::SkillsEvolve')
      register_if_defined('KairosMcp::Tools::SkillsRollback')
      
      # L1: knowledge/ (Anthropic skills format with hash-only blockchain record)
      register_if_defined('KairosMcp::Tools::KnowledgeList')
      register_if_defined('KairosMcp::Tools::KnowledgeGet')
      register_if_defined('KairosMcp::Tools::KnowledgeUpdate')
      register_if_defined('KairosMcp::Tools::KnowledgeScripts')
      register_if_defined('KairosMcp::Tools::KnowledgeAssets')
      
      # L2: context/ (Anthropic skills format without blockchain record)
      register_if_defined('KairosMcp::Tools::ContextSessions')
      register_if_defined('KairosMcp::Tools::ContextList')
      register_if_defined('KairosMcp::Tools::ContextGet')
      register_if_defined('KairosMcp::Tools::ContextSave')
      register_if_defined('KairosMcp::Tools::ContextCreateSubdir')
      
      # Chain tools
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
