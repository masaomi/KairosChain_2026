module KairosMcp
  # Guarantees block context
  class GuaranteesContext
    attr_reader :guarantees

    def initialize
      @guarantees = []
    end

    def method_missing(name, *args)
      @guarantees << name
      self
    end

    def respond_to_missing?(name, include_private = false)
      true
    end
  end

  # Effect block context
  class EffectContext
    attr_reader :name, :requirements, :recordings, :runner

    def initialize(name)
      @name = name
      @requirements = []
      @recordings = []
      @runner = nil
    end

    def requires(condition)
      @requirements << condition
    end

    def records(what)
      @recordings << what
    end

    def run(&block)
      @runner = block
    end

    def to_h
      {
        name: @name,
        requirements: @requirements,
        recordings: @recordings,
        has_runner: !@runner.nil?
      }
    end
  end

  # Tool block context - defines MCP tool interface and implementation
  class ToolContext
    attr_reader :tool_name, :tool_description, :executor

    def initialize
      @input_properties = {}
      @required_inputs = []
      @executor = nil
    end

    def name(value)
      @tool_name = value
    end

    def description(value)
      @tool_description = value
    end

    def input(&block)
      instance_eval(&block) if block_given?
    end

    def property(name, type:, description:)
      @input_properties[name.to_sym] = { type: type, description: description }
    end

    def required(*names)
      @required_inputs.concat(names.map(&:to_sym))
    end

    # Execute block for tool implementation (with args)
    def execute(&block)
      @executor = block
    end

    def input_schema
      {
        type: 'object',
        properties: @input_properties.transform_keys(&:to_s).transform_values { |v|
          { type: v[:type], description: v[:description] }
        },
        required: @required_inputs.map(&:to_s)
      }
    end

    def to_h
      {
        name: @tool_name,
        description: @tool_description,
        input_schema: input_schema,
        has_executor: !@executor.nil?
      }
    end
  end

  # Minimal AST node structure for partial formalization
  AstNode = Struct.new(:type, :name, :options, :source_span, keyword_init: true) do
    def to_h
      {
        type: type,
        name: name,
        options: options,
        source_span: source_span
      }
    end
  end

  # Definition block context — collects partially-formalized AST nodes
  # Used in the structural layer (definition block) of dual-representation Skills.
  # Nodes represent the subset of content that has been formalized into AST form.
  class DefinitionContext
    attr_reader :nodes

    def initialize
      @nodes = []
    end

    # Deterministic constraint (binary, measurable criteria)
    def constraint(name, **opts)
      @nodes << AstNode.new(
        type: :Constraint,
        name: name,
        options: opts,
        source_span: nil
      )
    end

    # Semantic reasoning node (delegates to LLM — formal expression of non-formalization)
    def node(name, type:, prompt:, source_span: nil)
      @nodes << AstNode.new(
        type: type.to_sym,
        name: name,
        options: { prompt: prompt },
        source_span: source_span
      )
    end

    # Execution step sequence (deterministic, order-dependent procedures)
    def plan(name, steps:)
      @nodes << AstNode.new(
        type: :Plan,
        name: name,
        options: { steps: steps },
        source_span: nil
      )
    end

    # External tool/command execution (strict parameter precision required)
    def tool_call(name, command:, **opts)
      @nodes << AstNode.new(
        type: :ToolCall,
        name: name,
        options: opts.merge(command: command),
        source_span: nil
      )
    end

    # Condition check (clear success/failure criteria)
    def check(name, condition:, **opts)
      @nodes << AstNode.new(
        type: :Check,
        name: name,
        options: opts.merge(condition: condition),
        source_span: nil
      )
    end

    def to_h
      { nodes: @nodes.map(&:to_h) }
    end
  end

  # Evolve block context
  class EvolveContext
    attr_reader :skill_id, :allowed, :denied, :conditions

    def initialize(skill_id)
      @skill_id = skill_id
      @allowed = []
      @denied = []
      @conditions = {}
    end

    def allow(*fields)
      @allowed.concat(fields)
    end

    def deny(*fields)
      @denied.concat(fields)
    end

    def when_condition(name, &block)
      @conditions[name] = block
    end

    def can_evolve?(field)
      return false if @denied.include?(field.to_sym) || @denied.include?(:all)
      @allowed.empty? || @allowed.include?(field.to_sym)
    end

    def to_h
      {
        skill_id: @skill_id,
        allowed: @allowed,
        denied: @denied,
        conditions: @conditions.keys
      }
    end
  end
end
