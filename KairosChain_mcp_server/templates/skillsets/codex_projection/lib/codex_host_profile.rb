# frozen_string_literal: true

# Codex host profile — add-on SkillSet contribution (design v0.3 FROZEN:
# docs/drafts/multi_host_projection_addon_design_v0.3_FROZEN.md).
#
# Codex CLI reads:
#   - AGENTS.md with the instruction-mode body inlined (Codex does not resolve @-import)
#   - <repo>/.codex/hooks.json — same event structure as Claude hooks, read natively
#   - .codex/skills/ and .codex/agents/ for projected skills/agents
#
# All conversion behavior travels with this profile (INV-H4); the core engine
# dispatches only through the profile abstraction.

require 'json'
require 'fileutils'

# NOTE: no `require 'kairos_mcp/plugin_projector'` here. This file is loaded by
# HostProfile.load_addons!, which runs inside the already-loaded core class; a
# path-based require could resolve to a different installed gem copy and
# double-define the class.
raise LoadError, 'codex_host_profile must be loaded via HostProfile.load_addons! (core not present)' unless defined?(KairosMcp::PluginProjector::HostProfile)

module KairosMcp
  module SkillSets
    module CodexProjection
      # Codex reads <repo>/.codex/hooks.json. KairosChain owns its projected
      # entries (tagged _projected_by), preserving user-authored hooks —
      # mirrors the Claude settings.json path so re-projection never destroys
      # user hooks. kairos-plugin-project commands are rewritten to re-project
      # this same host.
      HOOKS_WRITER = lambda do |projector, merged_hooks, outputs|
        projected_by = KairosMcp::PluginProjector::PROJECTED_BY
        hooks_file = File.join(projector.output_root, 'hooks.json')
        existing = projector.load_settings(hooks_file) # {} when absent, nil on parse error
        next if existing.nil?

        # A hand-authored file may hold a malformed 'hooks' (non-Hash, or non-Array
        # event values). Normalize before merging so projection never crashes; a
        # malformed 'hooks' carries no preservable user hooks anyway.
        existing['hooks'] = {} unless existing['hooks'].is_a?(Hash)
        existing['hooks'].transform_values! { |v| v.is_a?(Array) ? v : [] }

        existing['hooks'].each_value do |handlers|
          handlers.reject! { |h| h.is_a?(Hash) && h['_projected_by'] == projected_by }
        end
        existing['hooks'].delete_if { |_, v| v.empty? }

        projected = projector.rewrite_hook_commands_for_host(merged_hooks)
        unless projected['hooks'].empty?
          projected['hooks'].each do |event, handlers|
            existing['hooks'][event] ||= []
            existing['hooks'][event].concat(handlers.map { |h| h.merge('_projected_by' => projected_by) })
          end
        end

        existing.delete('hooks') if existing['hooks'].empty?
        # Only delete the file if nothing (projected or user) remains — never clobber user content.
        if existing.empty?
          FileUtils.rm_f(hooks_file)
          next
        end
        FileUtils.mkdir_p(File.dirname(hooks_file))
        projector.atomic_write(hooks_file, JSON.pretty_generate(existing))
        outputs[hooks_file] = { 'type' => 'hooks_codex_json' }
      end

      PROFILE = KairosMcp::PluginProjector::HostProfile.register(
        KairosMcp::PluginProjector::HostProfile.new(
          key: 'codex',
          output_subdir: '.codex',
          context_file: 'AGENTS.md',
          instruction_mode_delivery: :inline,
          manifest_suffix: 'codex',
          skill_projection: :own,
          agents_subdir: 'agents',
          aliases: [],
          requires_host: nil,
          hooks_writer: HOOKS_WRITER,
          agent_converter: nil
        ),
        source: 'skillset:codex_projection'
      )
    end
  end
end
