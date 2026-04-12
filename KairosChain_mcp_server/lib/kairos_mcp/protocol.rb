require 'json'
require_relative 'tool_registry'
require_relative 'skills_config'
require_relative 'upgrade_analyzer'
require_relative 'plugin_projector'
require_relative 'version'

module KairosMcp
  class Protocol
    # Protocol versions
    STDIO_PROTOCOL_VERSION = '2024-11-05'
    HTTP_PROTOCOL_VERSION = '2025-03-26'

    # =========================================================================
    # SkillSet Filter Registry
    # =========================================================================

    @filters = {}
    @filter_mutex = Mutex.new

    # Register a named request filter.
    # Filters transform user_context before it reaches ToolRegistry.
    def self.register_filter(name, &block)
      @filter_mutex.synchronize { @filters[name.to_sym] = block }
    end

    def self.unregister_filter(name)
      @filter_mutex.synchronize { @filters.delete(name.to_sym) }
    end

    # Apply all registered filters to user_context in registration order
    def self.apply_all_filters(user_context)
      @filter_mutex.synchronize { @filters.values.dup }.reduce(user_context) do |ctx, filter|
        filter.call(ctx)
      end
    end

    # For testing only
    def self.clear_filters!
      @filter_mutex.synchronize { @filters = {} }
    end

    # =========================================================================

    # @param user_context [Hash, nil] Authenticated user info from HTTP mode
    #   { user: "name", role: "owner"|"member"|"guest", ... }
    def initialize(user_context: nil)
      @user_context = self.class.apply_all_filters(user_context)
      @tool_registry = ToolRegistry.new(user_context: @user_context)
      @initialized = false
    end

    def handle_message(line)
      request = parse_json(line)
      return nil unless request

      id = request['id']
      method = request['method']
      params = request['params'] || {}

      result = case method
               when 'initialize'
                 handle_initialize(params)
               when 'initialized'
                 return nil
               when 'tools/list'
                 handle_tools_list
               when 'tools/call'
                 handle_tools_call(params)
               else
                 return nil
               end

      format_response(id, result)
    rescue StandardError => e
      format_error(id, -32603, "Internal error: #{e.message}")
    end

    private

    def parse_json(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def protocol_version
      @user_context ? HTTP_PROTOCOL_VERSION : STDIO_PROTOCOL_VERSION
    end

    def handle_initialize(params)
      roots = params['roots'] || params['workspaceFolders']
      @tool_registry.set_workspace(roots)
      @initialized = true

      result = {
        protocolVersion: protocol_version,
        capabilities: {
          tools: {
            # Phase 2: Set to true when notifications/tools/list_changed is implemented
            listChanged: false
          }
        },
        serverInfo: {
          name: 'kairos-chain',
          version: KairosMcp::VERSION
        }
      }

      # Add instructions based on config mode (developer/user/none)
      instructions = load_instructions
      result[:instructions] = instructions if instructions

      # One-time upgrade notification at session start
      notification = check_upgrade_available
      result[:notifications] = [notification] if notification

      # Plugin projection: project SkillSet artifacts to Claude Code structure
      project_plugin_artifacts

      result
    end

    def project_plugin_artifacts
      project_root = KairosMcp.project_root
      mode = KairosMcp.projection_mode
      projector = PluginProjector.new(project_root, mode: mode)
      manager = SkillSetManager.new
      enabled = manager.enabled_skillsets
      knowledge_entries = collect_knowledge_entries

      if @user_context # HTTP mode
        projector.project_if_changed!(enabled, knowledge_entries: knowledge_entries)
      else # stdio mode
        projector.project!(enabled, knowledge_entries: knowledge_entries)
      end
    rescue => e
      warn "[PluginProjector] projection failed: #{e.message}"
    end

    def collect_knowledge_entries
      KairosMcp.collect_knowledge_entries(user_context: @user_context)
    end

    # Load instructions based on instructions_mode in config.yml
    #
    # @return [String, nil] Instructions text or nil
    def load_instructions
      mode = SkillsConfig.load['instructions_mode'] || 'tutorial'

      path = case mode
             when 'developer'
               KairosMcp.md_path           # Full philosophy (kairos.md)
             when 'user'
               KairosMcp.quickguide_path   # Quick guide (kairos_quickguide.md)
             when 'tutorial'
               KairosMcp.tutorial_path     # Tutorial mode (kairos_tutorial.md)
             when 'none'
               nil
             else
               # Dynamic custom mode: resolve to skills/{mode}.md
               File.join(KairosMcp.skills_dir, "#{mode}.md")
             end

      return nil unless path

      read_if_exists(path)
    end

    # Read file content if it exists
    #
    # @param path [String] File path
    # @return [String, nil] File content or nil
    def read_if_exists(path)
      File.exist?(path) ? File.read(path) : nil
    end

    # Check if gem version differs from initialized data version
    #
    # @return [Hash, nil] Notification hash or nil
    def check_upgrade_available
      analyzer = UpgradeAnalyzer.new
      return nil unless analyzer.has_meta
      return nil unless analyzer.upgrade_needed?

      {
        type: 'upgrade_available',
        message: "KairosChain upgrade available: v#{analyzer.meta_version} → v#{analyzer.gem_version}. " \
                 "Run 'kairos-chain upgrade' to update your project files."
      }
    rescue StandardError
      nil
    end

    def handle_tools_list
      # Filter namespaced proxy tools (e.g., "peer1/tool") from external clients
      # to prevent infinite proxy loops. Internal call_tool/tool_exists? still sees them.
      tools = @tool_registry.list_tools.reject { |t| t[:name].to_s.include?('/') }
      { tools: tools }
    end

    def handle_tools_call(params)
      name = params['name']
      arguments = params['arguments'] || {}

      Thread.current[:kairos_user_context] = @user_context
      content = @tool_registry.call_tool(name, arguments)

      {
        content: content
      }
    ensure
      Thread.current[:kairos_user_context] = nil
    end

    def format_response(id, result)
      {
        jsonrpc: '2.0',
        id: id,
        result: result
      }
    end

    def format_error(id, code, message)
      {
        jsonrpc: '2.0',
        id: id,
        error: {
          code: code,
          message: message
        }
      }
    end
  end
end
