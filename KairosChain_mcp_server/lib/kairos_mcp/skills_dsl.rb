require_relative 'skill_contexts'
require_relative 'version_manager'

module KairosMcp
  class SkillsDsl
    # Extended Skill Struct with version, inputs, effects, evolution_rules, tool_config
    Skill = Struct.new(
      :id,
      :version,           # Skill version string
      :title,
      :use_when,
      :inputs,            # Array of input symbols
      :requires,
      :guarantees,        # Can be symbol or array of symbols
      :depends_on,
      :content,
      :behavior,
      :effects,           # Hash of EffectContext
      :evolution_rules,   # EvolveContext
      :created_at,        # Creation timestamp
      :tool_config,       # ToolContext - MCP tool definition
      keyword_init: true
    ) do
      # Check if a field can be evolved based on evolution_rules
      def can_evolve?(field)
        return true unless evolution_rules
        evolution_rules.can_evolve?(field)
      end

      # Get history from VersionManager
      def history
        return [] unless defined?(VersionManager)
        VersionManager.list_versions.select { |v| v[:filename].include?(id.to_s) }
      end

      # Check if this skill defines an MCP tool
      def has_tool?
        !tool_config.nil? && tool_config.executor
      end
      
      def to_h
        h = super
        h[:effects] = effects.transform_values(&:to_h) if effects
        h[:evolution_rules] = evolution_rules.to_h if evolution_rules
        h[:tool_config] = tool_config.to_h if tool_config
        h
      end
    end
    
    def self.load(path)
      dsl = new
      if File.exist?(path)
        dsl.instance_eval(File.read(path), path)
      end
      dsl.skills
    end
    
    def initialize
      @skills = []
    end
    
    attr_reader :skills
    
    def skill(id, &block)
      builder = SkillBuilder.new(id)
      builder.instance_eval(&block)
      @skills << builder.build
    end
  end
  
  class SkillBuilder
    def initialize(id)
      @id = id
      @data = { created_at: Time.now }
    end

    def version(value)
      @data[:version] = value
    end

    def title(value)
      @data[:title] = value
    end

    def use_when(value)
      @data[:use_when] = value
    end

    def inputs(*args)
      @data[:inputs] = args.flatten
    end

    def requires(value)
      @data[:requires] = value
    end

    def guarantees(value = nil, &block)
      if block_given?
        ctx = GuaranteesContext.new
        ctx.instance_eval(&block)
        @data[:guarantees] = ctx.guarantees
      else
        @data[:guarantees] = value
      end
    end

    def depends_on(value)
      @data[:depends_on] = value
    end

    def content(value)
      @data[:content] = value
    end

    def behavior(&block)
      @data[:behavior] = block
    end

    def effect(name, &block)
      @data[:effects] ||= {}
      ctx = EffectContext.new(name)
      ctx.instance_eval(&block) if block_given?
      @data[:effects][name] = ctx
    end

    def evolve(&block)
      ctx = EvolveContext.new(@id)
      ctx.instance_eval(&block) if block_given?
      @data[:evolution_rules] = ctx
    end

    # Define MCP tool interface and implementation
    def tool(&block)
      ctx = ToolContext.new
      ctx.instance_eval(&block) if block_given?
      @data[:tool_config] = ctx
    end

    def build
      SkillsDsl::Skill.new(id: @id, **@data)
    end
  end
end
