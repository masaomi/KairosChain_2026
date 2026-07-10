# frozen_string_literal: true

# OpenCode host profile — add-on SkillSet contribution (design v0.3 FROZEN:
# docs/drafts/multi_host_projection_addon_design_v0.3_FROZEN.md).
#
# OpenCode reads .claude/skills/ natively, so skills are NOT re-projected
# (Claude co-use assumption — declared as requires_host: 'claude', enforced
# pre-flight per INV-H5). AGENTS.md carries the inlined mode body (shared with
# Codex). Agents convert to .opencode/agent/ with OpenCode frontmatter. Hooks
# are JS/TS plugins — not deliverable declaratively, so hooks delivery warns
# and skips.
#
# All conversion behavior travels with this profile (INV-H4); the core engine
# dispatches only through the profile abstraction.

require 'yaml'

# NOTE: no `require 'kairos_mcp/plugin_projector'` here. This file is loaded by
# HostProfile.load_addons!, which runs inside the already-loaded core class; a
# path-based require could resolve to a different installed gem copy and
# double-define the class.
raise LoadError, 'opencode_host_profile must be loaded via HostProfile.load_addons! (core not present)' unless defined?(KairosMcp::PluginProjector::HostProfile)

require 'json'

module KairosMcp
  module SkillSets
    module OpencodeProjection
      # OpenCode hooks are JS/TS plugins, not a declarative file — cannot be projected here.
      HOOKS_WRITER = lambda do |_projector, merged_hooks, _outputs|
        next if merged_hooks['hooks'].empty?
        warn "[PluginProjector] WARNING: host 'opencode' uses plugin-based hooks (JS/TS); " \
             "skipping projection of #{merged_hooks['hooks'].size} hook event(s). Author an OpenCode plugin instead."
      end

      # Convert a Claude Code agent (.md + YAML frontmatter) to OpenCode agent frontmatter.
      #   - drop `name` (OpenCode derives the agent name from the filename)
      #   - drop `model` (OpenCode subagents inherit the caller's model — free-LLM friendly)
      #   - `disallowedTools: A, B` -> `tools: { a: false, b: false }`
      #   - add `mode: subagent`
      # Body (system prompt) is preserved verbatim. Returns input unchanged if no frontmatter.
      AGENT_CONVERTER = lambda do |content|
        m = content.match(/\A---\s*\n(.*?)\n---\s*\n?(.*)\z/m)
        next content unless m

        src = begin
          YAML.safe_load(m[1])
        rescue StandardError
          nil
        end
        next content unless src.is_a?(Hash)
        body = m[2]

        out = {}
        out['description'] = src['description'] if src['description']
        out['mode'] = 'subagent'
        if src['disallowedTools']
          # Accept both comma-string ("Write, Edit") and YAML list ([Write, Edit]) forms.
          disabled = Array(src['disallowedTools']).flat_map { |t| t.to_s.split(',') }
                                                  .map { |t| t.strip.downcase }.reject(&:empty?)
          out['tools'] = disabled.each_with_object({}) { |t, h| h[t] = false } unless disabled.empty?
        end

        front = YAML.dump(out).sub(/\A---\n/, '').rstrip
        "---\n#{front}\n---\n\n#{body.lstrip}"
      end

      # Project the kairos-chain MCP server into <project_root>/opencode.json so
      # OpenCode can call KairosChain tools. OpenCode's local-server MCP format is
      # `{ "mcp": { "<name>": { "type": "local", "command": [...], "enabled": true } } }`.
      # Merges the single kairos-chain key, preserving all other user config.
      MCP_CONFIG_WRITER = lambda do |projector, outputs|
        data_dir = File.expand_path(projector.data_dir)
        entry = {
          'type' => 'local',
          'command' => ['kairos-chain', '--data-dir', data_dir],
          'enabled' => true
        }
        projector.merge_project_root_json!('opencode.json', 'mcp', 'kairos-chain', entry,
                                           outputs, 'mcp_config_opencode')
      end

      PROFILE = KairosMcp::PluginProjector::HostProfile.register(
        KairosMcp::PluginProjector::HostProfile.new(
          key: 'opencode',
          output_subdir: '.opencode',
          context_file: 'AGENTS.md',
          instruction_mode_delivery: :inline,
          manifest_suffix: 'opencode',
          skill_projection: :reuse_claude,
          agents_subdir: 'agent',
          aliases: %w[open-code],
          requires_host: 'claude',
          hooks_writer: HOOKS_WRITER,
          agent_converter: AGENT_CONVERTER,
          mcp_config_writer: MCP_CONFIG_WRITER
        ),
        source: 'skillset:opencode_projection'
      )
    end
  end
end
