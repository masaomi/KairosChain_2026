require_relative 'safety'
require_relative 'tools/base_tool'
require_relative 'skills_config'
require_relative 'lifecycle_hook'

module KairosMcp
  class ToolRegistry
    # Authorization denial raised by registered gates
    class GateDeniedError < StandardError
      attr_reader :tool_name, :role
      def initialize(tool_name, role, msg = nil)
        @tool_name = tool_name
        @role = role
        super(msg || "Access denied: #{tool_name} requires higher privileges")
      end
    end

    # =========================================================================
    # SkillSet Gate Registry
    # =========================================================================

    @gates = {}
    @gate_mutex = Mutex.new

    # Register a named authorization gate.
    # Gates are called before every tool invocation with (tool_name, arguments, safety).
    # Raise GateDeniedError to deny access.
    def self.register_gate(name, &block)
      @gate_mutex.synchronize { @gates[name.to_sym] = block }
    end

    def self.unregister_gate(name)
      @gate_mutex.synchronize { @gates.delete(name.to_sym) }
    end

    def self.run_gates(tool_name, arguments, safety)
      @gate_mutex.synchronize { @gates.values.dup }.each do |gate|
        gate.call(tool_name, arguments, safety)
      end
    end

    # For testing only
    def self.clear_gates!
      @gate_mutex.synchronize { @gates = {} }
    end

    # =========================================================================

    # @param user_context [Hash, nil] Authenticated user info from HTTP mode
    def initialize(user_context: nil)
      @safety = Safety.new
      @safety.set_user(user_context) if user_context
      @tools = {}
      @tool_sources = {}     # { tool_name(String) => :core_tool | "skillset:<name>" } — Phase 1.5
      @lifecycle_hooks = {}  # { hook_name(Symbol) => { skillset:, class_name: } }
      register_tools
    end

    # 24/7 v0.4 §2.3 — LifecycleHook registry.
    #
    # Register a hook declaration from a SkillSet. Conflicts (same hook
    # name claimed by two SkillSets) raise LifecycleHook::Conflict — the
    # Bootstrap layer refuses to silently pick a winner.
    def register_lifecycle_hook(hook_name, class_name, skillset_name:)
      key = hook_name.to_sym
      # R1 P1 (2-voice security): validate class name + enforce namespace
      # allowlist before trusting any skillset-sourced class identifier.
      validated = LifecycleHook.validate_class_name!(class_name)

      existing = @lifecycle_hooks[key]
      if existing && existing[:skillset] != skillset_name
        raise LifecycleHook::Conflict,
              "LifecycleHook '#{hook_name}' claimed by both " \
              "'#{existing[:skillset]}' and '#{skillset_name}'"
      end
      # R1 P2 (3-voice): same-skillset re-registration must not silently
      # overwrite with a DIFFERENT class. Same-class re-registration is a
      # harmless idempotent load (tests, reload).
      if existing && existing[:class_name] != validated
        raise LifecycleHook::Conflict,
              "LifecycleHook '#{hook_name}' re-registered by " \
              "'#{skillset_name}' with different class " \
              "('#{existing[:class_name]}' → '#{validated}')"
      end
      @lifecycle_hooks[key] = { skillset: skillset_name, class_name: validated }
    end

    # Resolve a registered hook to its Class (without instantiating).
    # Returns nil if no SkillSet declared the hook. Raises
    # `LifecycleHook::UnknownClass` if the registered class name cannot
    # be constantized or does not include `LifecycleHook`.
    #
    # R8→R9 (3-voice: Codex P1 / 4.6 P2 / 4.7 P2): split class-resolution
    # from instantiation so bin/ can `.new` under a precise rescue. The
    # broad `rescue StandardError` in the entrypoint otherwise mislabels
    # any registry-logic bug as an instantiation failure.
    def lifecycle_hook_class(hook_name)
      entry = @lifecycle_hooks[hook_name.to_sym]
      return nil unless entry
      begin
        klass = Object.const_get(entry[:class_name])
      rescue NameError => e
        raise LifecycleHook::UnknownClass,
              "lifecycle hook class '#{entry[:class_name]}' is not defined " \
              "(declared by '#{entry[:skillset]}'): #{e.message}"
      end
      unless klass.is_a?(Class) && klass.include?(KairosMcp::LifecycleHook)
        raise LifecycleHook::UnknownClass,
              "class '#{entry[:class_name]}' does not include KairosMcp::LifecycleHook"
      end
      klass
    end

    # Instantiate a pre-resolved lifecycle hook class and verify the
    # resulting instance actually includes LifecycleHook (guards against
    # pathological `.new` overrides that return unrelated objects).
    #
    # Raises `LifecycleHook::InstanceViolation` if `.new` returns the
    # wrong type (a distinct contract violation, separate from lookup
    # failures that raise UnknownClass). Any other error from `.new`
    # propagates unchanged so the caller's rescue stays precise.
    #
    # R9→R10 (Codex P1 / 4.6 P2): shared helper so both `find_lifecycle_hook`
    # and bin/ get the same pathological-return guard.
    # R10→R11 (Codex P1 / 4.6 P3 / 4.7 P3): distinct exception class for
    # wrong-type returns — UnknownClass is semantically wrong here (the
    # class IS known; it violates the contract at instantiation).
    # R12→R13: `.new` return values may be arbitrary — including
    # `BasicObject` descendants that don't respond to `.class`, `.is_a?`,
    # or `.inspect`. Use `Module#===` for the type check (works on
    # BasicObject) and `Object.instance_method(:…).bind_call(obj)` with
    # rescue-everything fallbacks for error-message formatting.
    KERNEL_CLASS  = Object.instance_method(:class).freeze
    KERNEL_INSPECT = Object.instance_method(:inspect).freeze
    private_constant :KERNEL_CLASS, :KERNEL_INSPECT

    def instantiate_lifecycle_hook(klass)
      instance = klass.new
      # `KairosMcp::LifecycleHook === instance` uses Module#=== — does
      # not call any method on `instance`, so it works on BasicObject.
      unless KairosMcp::LifecycleHook === instance
        class_label =
          (klass.name && !klass.name.empty?) ? klass.name : klass.inspect
        raise LifecycleHook::InstanceViolation,
              "#{class_label}.new returned #{safe_inspect(instance)} " \
              "(#{safe_class_name(instance)}) which does not include " \
              'KairosMcp::LifecycleHook'
      end
      instance
    end

    # Safely render the class of an arbitrary object — including
    # BasicObject descendants — without calling methods that may be
    # missing on the object.
    def safe_class_name(obj)
      KERNEL_CLASS.bind_call(obj).to_s
    rescue Exception # rubocop:disable Lint/RescueException
      '<class unavailable>'
    end
    private :safe_class_name

    # Safe .inspect — tolerates pathological objects whose inspect or
    # class is undefined/raises.
    def safe_inspect(obj)
      KERNEL_INSPECT.bind_call(obj)
    rescue Exception # rubocop:disable Lint/RescueException
      "<#{safe_class_name(obj)} (inspect raised)>"
    end
    private :safe_inspect

    # Convenience: resolve the class and instantiate. Retained for tests
    # and callers that do not need to distinguish lookup failures from
    # constructor failures.
    def find_lifecycle_hook(hook_name)
      klass = lifecycle_hook_class(hook_name)
      return nil unless klass
      instantiate_lifecycle_hook(klass)
    end

    def lifecycle_hook_names
      @lifecycle_hooks.keys
    end

    def register_tools
      # Load all tool files
      Dir[File.join(__dir__, 'tools', '*.rb')].each do |file|
        require file
      end

      # Register tools
      register_if_defined('KairosMcp::Tools::HelloWorld')

      # Phase 1.5 — Capability Boundary self-articulation
      register_if_defined('KairosMcp::Tools::CapabilityStatus')

      # L0-A: skills/kairos.md (read-only)
      register_if_defined('KairosMcp::Tools::SkillsList')
      register_if_defined('KairosMcp::Tools::SkillsGet')
      
      # L0-B: skills/kairos.rb (self-modifying with full blockchain record)
      register_if_defined('KairosMcp::Tools::SkillsDslList')
      register_if_defined('KairosMcp::Tools::SkillsDslGet')
      register_if_defined('KairosMcp::Tools::SkillsEvolve')
      register_if_defined('KairosMcp::Tools::SkillsRollback')
      
      # Cross-layer promotion with optional Persona Assembly
      register_if_defined('KairosMcp::Tools::SkillsPromote')
      
      # Audit tools (health checks, archive management, recommendations)
      register_if_defined('KairosMcp::Tools::SkillsAudit')

      # L0: Instructions management (system prompt control with full blockchain record)
      register_if_defined('KairosMcp::Tools::InstructionsUpdate')
      
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
      register_if_defined('KairosMcp::Tools::ChainExport')
      register_if_defined('KairosMcp::Tools::ChainImport')

      # Formalization tools (DSL/AST partial formalization records)
      register_if_defined('KairosMcp::Tools::FormalizationRecord')
      register_if_defined('KairosMcp::Tools::FormalizationHistory')

      # Definition analysis tools (Phase 2: verification, decompilation, drift detection)
      register_if_defined('KairosMcp::Tools::DefinitionVerify')
      register_if_defined('KairosMcp::Tools::DefinitionDecompile')
      register_if_defined('KairosMcp::Tools::DefinitionDrift')

      # State commit tools (auditability)
      register_if_defined('KairosMcp::Tools::StateCommit')
      register_if_defined('KairosMcp::Tools::StateStatus')
      register_if_defined('KairosMcp::Tools::StateHistory')

      # Guide tools (discovery, help, metadata management)
      register_if_defined('KairosMcp::Tools::ToolGuide')

      # Token management (HTTP authentication)
      register_if_defined('KairosMcp::Tools::TokenManage')

      # System management tools (upgrade, migration)
      register_if_defined('KairosMcp::Tools::SystemUpgrade')

      # SkillSet-based tools (opt-in plugins from .kairos/skillsets/)
      register_skillset_tools

      # Skill-based tools (from kairos.rb with tool block)
      register_skill_tools if skill_tools_enabled?

      # Restore dynamic proxy tools from active mcp_client connections (Phase 4)
      restore_dynamic_tools
    end

    # Register tools from enabled SkillSets
    def register_skillset_tools
      require_relative 'skillset_manager'

      manager = SkillSetManager.new
      manager.enabled_skillsets.each do |skillset|
        skillset.load!
        skillset.tool_class_names.each do |cls|
          # Phase 1.5: thread source attribution for capability_status manifest
          register_if_defined(cls, source: "skillset:#{skillset.name}")
        end
        # 24/7 v0.4 §2.3 — register lifecycle hooks declared by this SkillSet.
        skillset.lifecycle_hooks.each do |hook_name, class_name|
          register_lifecycle_hook(hook_name, class_name, skillset_name: skillset.name)
        end
      end
    rescue LifecycleHook::Conflict
      raise  # never swallow — Bootstrap integrity depends on detection
    rescue StandardError => e
      warn "[ToolRegistry] Failed to load SkillSet tools: #{e.message}"
    end

    # Register tools defined in kairos.rb via tool block
    def register_skill_tools
      require_relative 'skill_tool_adapter'
      require_relative 'kairos'

      Kairos.skills.each do |skill|
        next unless skill.has_tool?  # Only skills with tool block and executor
        adapter = SkillToolAdapter.new(skill, @safety, registry: self)
        register(adapter)
      end
    end

    def set_workspace(roots)
      @safety.set_workspace(roots)
    end

    def list_tools
      @tools.values.map(&:to_schema)
    end

    # Register a pre-built tool instance (e.g., proxy tools from mcp_client).
    # Cannot overwrite local (non-proxy) tools to prevent accidental replacement.
    def register_dynamic_tool(tool_instance)
      name = tool_instance.name
      existing = @tools[name]
      if existing && !existing.respond_to?(:remote_name)
        raise "Cannot override local tool '#{name}' with dynamic registration"
      end
      @tools[name] = tool_instance
      @tool_sources[name] = :dynamic_proxy
    end

    # Remove a dynamically registered tool (e.g., on mcp_disconnect).
    def unregister_tool(name)
      @tool_sources.delete(name)
      @tools.delete(name)
    end

    def call_tool(name, arguments, invocation_context: nil)
      tool = @tools[name]
      unless tool
        raise "Tool not found: #{name}"
      end

      # Defense-in-depth: enforce invocation policy at the registry boundary.
      # This duplicates the check in BaseTool#invoke_tool so that direct
      # call_tool calls with a context also respect whitelist/blacklist.
      if invocation_context && !invocation_context.allowed?(name)
        raise InvocationContext::PolicyDeniedError,
              "Tool '#{name}' blocked by invocation policy at registry boundary"
      end

      self.class.run_gates(name, arguments, @safety)
      tool.call(arguments)
    rescue GateDeniedError => e
      [{ type: 'text', text: JSON.pretty_generate({ error: 'forbidden', message: e.message }) }]
    rescue InvocationContext::DepthExceededError, InvocationContext::PolicyDeniedError => e
      [{ type: 'text', text: JSON.pretty_generate({ error: 'invocation_denied', message: e.message }) }]
    end

    private

    def skill_tools_enabled?
      SkillsConfig.load['skill_tools_enabled'] == true
    end

    def register_if_defined(class_name, source: :core_tool)
      klass = Object.const_get(class_name)
      register(klass.new(@safety, registry: self), source: source)
    rescue NameError
      # Class not defined yet (file might not exist), ignore
    end

    def register(tool, source: :core_tool)
      @tools[tool.name] = tool
      @tool_sources[tool.name] = source
    end

    # Restore dynamic proxy tools from active mcp_client connections.
    # Called at the end of register_tools so that HTTP-mode registries
    # (which are recreated per request) pick up existing connections.
    def restore_dynamic_tools
      return unless defined?(KairosMcp::SkillSets::McpClient::ConnectionManager)

      conn_mgr = KairosMcp::SkillSets::McpClient::ConnectionManager.instance
      conn_mgr.restore_proxy_tools(self, @safety)
    rescue StandardError
      nil  # mcp_client SkillSet may not be loaded
    end
  end
end
