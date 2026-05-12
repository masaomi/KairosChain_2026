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
      # Auto-init: initialize .kairos/ if it doesn't exist yet
      unless KairosMcp.initialized?
        require_relative 'initializer'
        KairosMcp::Initializer.run(quiet: true)
      end

      manager = SkillSetManager.new

      # Auto-install: install core SkillSets only (no external deps)
      if manager.all_skillsets.empty?
        manager.upgrade_apply(core_only: true)
      end

      # Project plugin artifacts (only if .claude/ exists — avoids creating
      # Claude Code artifacts for non-Claude clients like Cursor or Codex)
      #
      # Design v0.2: resolve consumer_project_root explicitly. Skip projection if
      # no plausible root is available (Inv 5: graceful skip). Refuse on coincidence
      # with data_dir (Inv 3, raised by PluginProjector constructor).
      project_root = KairosMcp.consumer_project_root
      if project_root.nil?
        warn "[PluginProjector] no plausible consumer project root resolved " \
             "(source: #{KairosMcp.consumer_project_root_source}); projection skipped"
        return
      end

      mode = KairosMcp.projection_mode
      output_root = mode == :plugin ? project_root : File.join(project_root, '.claude')
      return unless File.directory?(output_root)

      begin
        projector = PluginProjector.new(project_root, mode: mode, data_dir: KairosMcp.data_dir)
      rescue PluginProjector::CoincidenceRefused => e
        warn "[PluginProjector] #{e.message}; projection skipped"
        return
      end
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

    # Load instructions based on instructions_mode in config.yml.
    #
    # Three states:
    #   1. Projected (manifest present, region in CLAUDE.md): returns a slim
    #      identity+pointer payload. Full body reaches the model via CLAUDE.md
    #      @-import (the privileged delivery path verified in Theme A).
    #   2. Not yet projected: returns the full body prefixed with a first-run
    #      hint that tells the LLM how to complete setup (`kairos-chain mode
    #      project` + restart). Backward-compatible — body still reaches the
    #      model on this channel, just truncated by the harness as before.
    #   3. mode == 'none': returns nil.
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

      if instruction_mode_projected?(mode)
        slim_instructions_payload(mode, path)
      else
        body = read_if_exists(path)
        return nil if body.nil?
        "#{first_run_setup_hint(mode)}\n---\n\n#{body}"
      end
    end

    # First-run setup hint prepended to instructions when the instruction
    # mode body has not yet been projected. Visible to the LLM in the
    # truncated MCP `instructions` channel; lets the LLM proactively guide
    # the user through one-time setup without needing prior knowledge.
    def first_run_setup_hint(mode)
      <<~HINT.strip
        # kairos-chain first-run setup notice

        The active instruction mode body ('#{mode}') has NOT been projected to
        this project's CLAUDE.md yet. The MCP `instructions` channel below is
        truncated by the Claude Code harness; Agent tool sub-agents do not
        receive this channel at all.

        To deliver the full mode body to all surfaces (parent + subprocess +
        sub-agent), run from the project root:

            kairos-chain mode project

        Then restart Claude Code (`exit` then `claude`). After projection,
        this notice disappears and this MCP channel switches to a slim
        identity+pointer payload.

        If you (the LLM) detect this notice in your context, surface this
        setup step to the user with explanation, ask for approval, run the
        command, and instruct them to restart.
      HINT
    end

    # True if the active instruction mode has been projected for this project.
    # v0.2: manifest now lives at data_dir level (decoupled from project_root).
    def instruction_mode_projected?(mode)
      manifest_path = File.join(KairosMcp.data_dir, 'instruction_mode_manifest.json')
      return false unless File.exist?(manifest_path)
      data = JSON.parse(File.read(manifest_path))
      data['mode_name'] == mode && data['region_present']
    rescue StandardError
      false
    end

    # Identity + pointer payload sent over MCP `instructions` when the body
    # is delivered via CLAUDE.md @-import. Short enough to clear the harness
    # truncation cap. Non-Claude-Code consumers retrieve the body from the
    # registry path directly.
    def slim_instructions_payload(mode, body_path)
      version_line = read_if_exists(body_path).to_s[/^\*\*Version:\*\*\s*\S+/i]
      <<~PAYLOAD
        # Active instruction mode (delivered via CLAUDE.md @-import)

        - mode_name: #{mode}
        - #{version_line || 'Version: (none recorded)'}
        - source_path: #{body_path}

        The full mode body is delivered to the model through this project's
        CLAUDE.md `@`-import line and is not duplicated here. Non-Claude-Code
        consumers can retrieve the body from the source_path above.

        Re-run `kairos-chain mode project` after editing the source body
        and restart Claude Code to apply changes.
      PAYLOAD
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
