# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'tempfile'
require 'time'
require 'pathname'

module KairosMcp
  # Projects SkillSet plugin artifacts to Claude Code plugin/project structure.
  #
  # Dual-mode:
  #   :project (default) — writes to .claude/skills/, .claude/agents/, .claude/settings.json
  #   :plugin            — writes to plugin root skills/, agents/, hooks/hooks.json
  #
  # Design: log/skillset_plugin_projection_design_v2.2_20260404.md
  class PluginProjector
    SEED_SKILLS = %w[kairos-chain].freeze
    PROJECTED_BY = 'kairos-chain'
    SAFE_NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/
    ALLOWED_HOOK_COMMANDS = /\Akairos-/

    INSTRUCTION_MODE_MARKER_BEGIN = '<!-- BEGIN kairos-chain:instruction-mode _projected_by=kairos-chain -->'
    INSTRUCTION_MODE_MARKER_END   = '<!-- END kairos-chain:instruction-mode -->'
    INSTRUCTION_MODE_REL_PATH     = 'kairos/instruction_mode.md'
    INSTRUCTION_MODE_SIZE_WARN    = 150 * 1024
    INSTRUCTION_MODE_SIZE_REFUSE  = 256 * 1024

    attr_reader :mode, :project_root, :output_root

    def initialize(project_root, mode: :auto)
      @project_root = project_root
      @mode = resolve_mode(mode)
      @output_root = @mode == :plugin ? project_root : File.join(project_root, '.claude')
      @manifest_path = File.join(project_root, '.kairos', 'projection_manifest.json')
      @instruction_mode_manifest_path = File.join(project_root, '.kairos', 'instruction_mode_manifest.json')
    end

    # Main entry: project all SkillSet plugin artifacts + L1 knowledge meta skill
    def project!(enabled_skillsets, knowledge_entries: [])
      previous_manifest = load_manifest
      current_outputs = {}
      merged_hooks = @mode == :plugin ? load_seed_hooks : { 'hooks' => {} }

      enabled_skillsets.each do |ss|
        next unless ss.has_plugin?

        plugin_dir = File.join(ss.path, 'plugin')
        project_skill!(ss, plugin_dir, current_outputs)
        project_agents!(ss, plugin_dir, current_outputs)
        collect_hooks!(ss, plugin_dir, merged_hooks)
      end

      project_knowledge_meta_skill!(knowledge_entries, current_outputs)
      write_merged_hooks!(merged_hooks, current_outputs)
      cleanup_stale!(previous_manifest, current_outputs)
      save_manifest(current_outputs, enabled_skillsets, knowledge_entries)
    end

    # Digest-based no-op: skip projection if nothing changed
    def project_if_changed!(enabled_skillsets, knowledge_entries: [])
      digest = compute_source_digest(enabled_skillsets, knowledge_entries)
      return false if digest == load_manifest.dig('source_digest')
      project!(enabled_skillsets, knowledge_entries: knowledge_entries)
      true
    end

    # Status summary for MCP tool
    def status
      manifest = load_manifest
      {
        mode: @mode,
        output_root: @output_root,
        projected_at: manifest['projected_at'],
        source_digest: manifest['source_digest'],
        output_count: manifest.fetch('outputs', {}).size
      }
    end

    # Verify projected files match manifest
    def verify
      manifest = load_manifest
      outputs = manifest.fetch('outputs', {})
      missing = outputs.keys.reject { |f| File.exist?(f) }
      orphaned = find_orphaned_files(outputs)
      { valid: missing.empty? && orphaned.empty?, missing: missing, orphaned: orphaned }
    end

    # =========================================================================
    # Instruction mode projection
    #   See: log/20260507_plugin_projector_instruction_mode_implementation_plan.md
    #
    # Materializes the active instruction mode body to a flat file under
    # <output_root>/<INSTRUCTION_MODE_REL_PATH>, then merges a managed marker
    # region into project-root CLAUDE.md so the harness picks it up via
    # `@`-import at session start. State for this artifact is tracked in a
    # separate manifest (.kairos/instruction_mode_manifest.json) to avoid
    # mixing symbolic region keys into the main projection manifest.
    # =========================================================================

    # Project the active instruction mode body.
    #
    # @param mode_name [String] active mode name (e.g., 'masa', 'tutorial')
    # @param body [String] flat mode body (no @-imports inside)
    # @param mode_version [String, nil] optional version label for the marker header
    # @return [Hash] result summary { artifact_path:, region_written:, size_bytes: }
    def project_instruction_mode!(mode_name, body, mode_version: nil)
      raise ArgumentError, "unsafe mode name: #{mode_name.inspect}" unless safe_name?(mode_name)

      size = body.bytesize
      raise InstructionModeTooLarge.new(size, INSTRUCTION_MODE_SIZE_REFUSE) if size > INSTRUCTION_MODE_SIZE_REFUSE
      warn "[PluginProjector] WARNING: instruction mode body is #{size} bytes (warn threshold #{INSTRUCTION_MODE_SIZE_WARN})" if size > INSTRUCTION_MODE_SIZE_WARN

      artifact_path = File.join(@output_root, INSTRUCTION_MODE_REL_PATH)
      raise "instruction mode artifact path outside output_root: #{artifact_path}" unless safe_path?(artifact_path)

      FileUtils.mkdir_p(File.dirname(artifact_path))
      atomic_write(artifact_path, body)

      region_written = merge_instruction_mode_region!(mode_name, mode_version, artifact_path)

      save_instruction_mode_manifest(
        'mode_name' => mode_name,
        'mode_version' => mode_version,
        'artifact_path' => artifact_path,
        'artifact_size' => size,
        'artifact_digest' => Digest::SHA256.hexdigest(body),
        'region_present' => region_written,
        'projected_at' => Time.now.utc.iso8601
      )

      { artifact_path: artifact_path, region_written: region_written, size_bytes: size }
    end

    # Remove the projected instruction mode artifact and CLAUDE.md region.
    #
    # @return [Hash] result summary { artifact_removed:, region_removed: }
    def remove_projected_instruction_mode!
      manifest = load_instruction_mode_manifest
      artifact_path = manifest['artifact_path'] || File.join(@output_root, INSTRUCTION_MODE_REL_PATH)

      artifact_removed = false
      if File.exist?(artifact_path) && safe_path?(artifact_path)
        FileUtils.rm_f(artifact_path)
        parent = File.dirname(artifact_path)
        FileUtils.rmdir(parent) if Dir.exist?(parent) && Dir.empty?(parent)
        artifact_removed = true
      end

      region_removed = remove_instruction_mode_region!

      save_instruction_mode_manifest(nil) # clear

      { artifact_removed: artifact_removed, region_removed: region_removed }
    end

    # Status summary for the instruction mode projection.
    def instruction_mode_status
      manifest = load_instruction_mode_manifest
      {
        mode: @mode,
        active: !manifest.empty?,
        mode_name: manifest['mode_name'],
        mode_version: manifest['mode_version'],
        artifact_path: manifest['artifact_path'],
        artifact_size: manifest['artifact_size'],
        region_present: manifest['region_present'],
        projected_at: manifest['projected_at']
      }
    end

    # Raised when a mode body exceeds the hard refusal threshold.
    class InstructionModeTooLarge < StandardError
      def initialize(size, limit)
        super("instruction mode body too large: #{size} bytes exceeds limit #{limit}")
      end
    end

    private

    def resolve_mode(mode)
      return mode unless mode == :auto
      return :plugin if ENV['KAIROS_PROJECTION_MODE'] == 'plugin'
      :project
    end

    # =========================================================================
    # Skill projection
    # =========================================================================

    def project_skill!(ss, plugin_dir, outputs)
      src = File.join(plugin_dir, 'SKILL.md')
      return unless File.exist?(src)
      return if SEED_SKILLS.include?(ss.name)
      return unless safe_name?(ss.name)

      template = File.read(src)
      tools_section = generate_tools_section(ss)
      content = inject_section(template, '<!-- AUTO_TOOLS -->', tools_section)

      target = File.join(@output_root, 'skills', ss.name, 'SKILL.md')
      return unless safe_path?(target)
      FileUtils.mkdir_p(File.dirname(target))
      atomic_write(target, content)
      outputs[target] = { 'source' => src, 'type' => 'skill', 'skillset' => ss.name }
    end

    # Ruby introspection: generate Available Tools section from tool classes
    # Returns nil if all tools fail introspection (preserves static template)
    def generate_tools_section(ss)
      return nil if ss.tool_class_names.empty?

      results = ss.tool_class_names.map do |class_name|
        begin
          klass = Object.const_get(class_name)
          instance = klass.new
          schema = instance.input_schema
          params = format_params(schema)
          { success: true, md: "### `#{instance.name}`\n#{instance.description}\n#{params}" }
        rescue => e
          { success: false, md: "### `#{class_name}` (introspection failed: #{e.message})" }
        end
      end

      return nil if results.none? { |r| r[:success] }
      results.map { |r| r[:md] }.join("\n\n")
    end

    def format_params(schema)
      props = schema.is_a?(Hash) ? (schema[:properties] || schema['properties'] || {}) : {}
      required = schema.is_a?(Hash) ? (schema[:required] || schema['required'] || []) : []
      props.map do |name, spec|
        type = spec[:type] || spec['type'] || 'string'
        desc = spec[:description] || spec['description'] || ''
        req = required.include?(name.to_s) ? ', required' : ''
        "- `#{name}` (#{type}#{req}): #{desc}"
      end.join("\n")
    end

    # =========================================================================
    # Agent projection
    # =========================================================================

    def project_agents!(ss, plugin_dir, outputs)
      agents_src = File.join(plugin_dir, 'agents')
      return unless Dir.exist?(agents_src)
      return unless safe_name?(ss.name)
      Dir.glob(File.join(agents_src, '*.md')).each do |f|
        target = File.join(@output_root, 'agents', "#{ss.name}-#{File.basename(f)}")
        next unless safe_path?(target)
        FileUtils.mkdir_p(File.dirname(target))
        atomic_write(target, File.read(f))
        outputs[target] = { 'source' => f, 'type' => 'agent', 'skillset' => ss.name }
      end
    end

    # =========================================================================
    # L1 Knowledge meta skill
    # =========================================================================

    def project_knowledge_meta_skill!(knowledge_entries, outputs)
      return if knowledge_entries.empty?

      list_md = knowledge_entries.map do |entry|
        tags = (entry[:tags] || []).first(3).join(', ')
        "| `#{entry[:name]}` | #{entry[:description]} | #{tags} |"
      end.join("\n")

      table = "| Name | Description | Tags |\n|------|-------------|------|\n#{list_md}"

      content = knowledge_meta_skill_template(knowledge_entries.size)
      content = inject_section(content, '<!-- AUTO_KNOWLEDGE_LIST -->', table)

      target = File.join(@output_root, 'skills', 'kairos-knowledge', 'SKILL.md')
      FileUtils.mkdir_p(File.dirname(target))
      atomic_write(target, content)
      outputs[target] = { 'type' => 'knowledge_meta_skill', 'knowledge_count' => knowledge_entries.size }
    end

    def knowledge_meta_skill_template(count)
      <<~SKILL
        ---
        name: kairos-knowledge
        description: >
          Access KairosChain L1 knowledge base. Use when the user needs domain knowledge,
          project conventions, workflow patterns, or accumulated insights from previous sessions.
        _projected_by: #{PROJECTED_BY}
        _knowledge_count: #{count}
        _last_projected: "#{Time.now.utc.iso8601}"
        ---

        # KairosChain Knowledge Base

        L1 knowledge is dynamically managed through the KairosChain layer system.

        ## How to Access Knowledge

        1. **Browse**: `knowledge_list` — see all available L1 knowledge
        2. **Read**: `knowledge_get name="xxx"` — read specific knowledge content
        3. **Search**: `knowledge_list query="keyword"` — filter by keyword
        4. **Promote**: `skills_promote` — promote L2 session context to L1 knowledge

        ## Currently Available Knowledge

        <!-- AUTO_KNOWLEDGE_LIST -->
      SKILL
    end

    # =========================================================================
    # Hooks projection (dual-mode)
    # =========================================================================

    def collect_hooks!(ss, plugin_dir, merged_hooks)
      hooks_file = File.join(plugin_dir, 'hooks.json')
      return unless File.exist?(hooks_file)
      ss_hooks = JSON.parse(File.read(hooks_file))
      ss_hooks.fetch('hooks', {}).each do |event, handlers|
        merged_hooks['hooks'][event] ||= []
        handlers.each do |h|
          existing = merged_hooks['hooks'][event].find { |e| e['matcher'] == h['matcher'] }
          if existing
            warn "[PluginProjector] WARNING: duplicate matcher '#{h['matcher']}' for #{event} from #{ss.name}"
          end
          # Warn about non-standard hook commands
          cmd = h.dig('hooks', 0, 'command') || h['command']
          if cmd && !cmd.match?(ALLOWED_HOOK_COMMANDS)
            warn "[PluginProjector] WARNING: non-standard hook command '#{cmd}' from #{ss.name}. Review for safety."
          end
        end
        merged_hooks['hooks'][event].concat(handlers)
      end
    rescue JSON::ParserError => e
      warn "[PluginProjector] ERROR: #{hooks_file} has invalid JSON: #{e.message}"
    end

    def write_merged_hooks!(merged_hooks, outputs)
      if @mode == :plugin
        write_hooks_file!(merged_hooks, outputs)
      else
        write_hooks_to_settings!(merged_hooks, outputs)
      end
    end

    # Plugin mode: write hooks/hooks.json
    def write_hooks_file!(merged_hooks, outputs)
      hooks_dir = File.join(@output_root, 'hooks')
      hooks_file = File.join(hooks_dir, 'hooks.json')
      if merged_hooks['hooks'].empty?
        FileUtils.rm_f(hooks_file)
      else
        FileUtils.mkdir_p(hooks_dir)
        atomic_write(hooks_file, JSON.pretty_generate(merged_hooks))
        outputs[hooks_file] = { 'type' => 'hooks_merged' }
      end
    end

    # Project mode: merge hooks into .claude/settings.json
    def write_hooks_to_settings!(merged_hooks, outputs)
      settings_path = File.join(@output_root, 'settings.json')
      settings = load_settings(settings_path)
      return if settings.nil? # JSON parse failed, abort

      remove_projected_hooks!(settings)

      unless merged_hooks['hooks'].empty?
        settings['hooks'] ||= {}
        merged_hooks['hooks'].each do |event, handlers|
          settings['hooks'][event] ||= []
          tagged = handlers.map { |h| h.merge('_projected_by' => PROJECTED_BY) }
          settings['hooks'][event].concat(tagged)
        end
      end

      # Clean up empty hooks
      settings['hooks']&.delete_if { |_, v| v.is_a?(Array) && v.empty? }
      settings.delete('hooks') if settings['hooks']&.empty?

      atomic_write(settings_path, JSON.pretty_generate(settings))
      outputs[settings_path] = { 'type' => 'hooks_settings_merge' }
    end

    # Remove only hooks projected by KairosChain, preserve user hooks
    def remove_projected_hooks!(settings)
      return unless settings['hooks']
      settings['hooks'].each do |_event, handlers|
        next unless handlers.is_a?(Array)
        handlers.reject! { |h| h['_projected_by'] == PROJECTED_BY }
      end
      settings['hooks'].delete_if { |_, v| v.is_a?(Array) && v.empty? }
      settings.delete('hooks') if settings['hooks']&.empty?
    end

    # Load settings.json with error handling (P1-2)
    def load_settings(path)
      return {} unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      warn "[PluginProjector] ERROR: #{path} has invalid JSON (#{e.message}). Skipping hooks merge."
      nil
    end

    # Plugin mode: load seed hooks from .kairos/seed_hooks.json
    def load_seed_hooks
      seed_path = File.join(@project_root, '.kairos', 'seed_hooks.json')
      if File.exist?(seed_path)
        JSON.parse(File.read(seed_path))
      else
        { 'hooks' => {} }
      end
    rescue JSON::ParserError
      { 'hooks' => {} }
    end

    # =========================================================================
    # Cleanup & Manifest
    # =========================================================================

    def cleanup_stale!(previous_manifest, current_outputs)
      previous_files = previous_manifest.fetch('outputs', {}).keys
      current_files = current_outputs.keys
      stale = previous_files - current_files
      stale.each do |f|
        # Path safety: only delete files under output_root
        canonical = File.expand_path(f)
        unless canonical.start_with?(File.expand_path(@output_root))
          warn "[PluginProjector] WARNING: skipping stale cleanup of '#{f}' (outside output_root)"
          next
        end
        FileUtils.rm_f(canonical)
        dir = File.dirname(canonical)
        FileUtils.rmdir(dir) if Dir.exist?(dir) && Dir.empty?(dir)
      rescue Errno::ENOTEMPTY, Errno::ENOENT
        # Directory not empty or already removed
      end
    end

    def compute_source_digest(enabled_skillsets, knowledge_entries = [])
      ss_content = enabled_skillsets.select(&:has_plugin?).map do |ss|
        "#{ss.name}:#{ss.version}:#{ss.content_hash}"
      end.join('|')

      # Include description and tags in digest (Codex P1-5: detect metadata changes)
      k_content = knowledge_entries.map do |e|
        tags = (e[:tags] || []).join(',')
        "#{e[:name]}:#{e[:version] || '0'}:#{e[:description]}:#{tags}"
      end.join('|')

      Digest::SHA256.hexdigest("#{ss_content}||#{k_content}")
    end

    def load_manifest
      return {} unless File.exist?(@manifest_path)
      JSON.parse(File.read(@manifest_path))
    rescue JSON::ParserError
      {}
    end

    def save_manifest(outputs, enabled_skillsets = [], knowledge_entries = [])
      manifest = {
        'projected_at' => Time.now.utc.iso8601,
        'source_digest' => compute_source_digest(enabled_skillsets, knowledge_entries),
        'mode' => @mode.to_s,
        'output_root' => @output_root,
        'outputs' => outputs
      }
      FileUtils.mkdir_p(File.dirname(@manifest_path))
      atomic_write(@manifest_path, JSON.pretty_generate(manifest))
    end

    def find_orphaned_files(manifest_outputs)
      projected_dirs = [
        File.join(@output_root, 'skills'),
        File.join(@output_root, 'agents')
      ]
      actual_files = projected_dirs.flat_map do |dir|
        next [] unless Dir.exist?(dir)
        Dir.glob(File.join(dir, '**', '*')).select { |f| File.file?(f) }
      end
      # Files in projected dirs not in manifest (excluding seed skills)
      actual_files.reject do |f|
        manifest_outputs.key?(f) || SEED_SKILLS.any? { |s| f.include?("/skills/#{s}/") }
      end
    end

    # =========================================================================
    # Utilities
    # =========================================================================

    # Validate SkillSet name against traversal patterns
    def safe_name?(name)
      unless name.match?(SAFE_NAME_PATTERN)
        warn "[PluginProjector] WARNING: unsafe SkillSet name '#{name}', skipping projection"
        return false
      end
      true
    end

    # Validate target path is under output_root
    def safe_path?(target)
      canonical = File.expand_path(target)
      unless canonical.start_with?(File.expand_path(@output_root))
        warn "[PluginProjector] WARNING: path '#{target}' is outside output_root, skipping"
        return false
      end
      true
    end

    # Atomic write: tmpfile + rename to prevent partial reads (P1-1)
    def atomic_write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = Tempfile.new([File.basename(path), File.extname(path)], File.dirname(path))
      tmp.write(content)
      tmp.close
      File.rename(tmp.path, path)
    rescue => e
      tmp&.close
      tmp&.unlink
      raise e
    end

    def inject_section(template, marker, content)
      return template if content.nil?
      if template.include?(marker)
        template.gsub(marker, content)
      else
        template
      end
    end

    # =========================================================================
    # Instruction mode helpers (private)
    # =========================================================================

    # Merge or insert the managed marker region in project-root CLAUDE.md.
    # Returns true if the region is now present, false otherwise.
    def merge_instruction_mode_region!(mode_name, mode_version, artifact_path)
      claudemd = claudemd_path
      return false unless safe_claudemd_path?(claudemd)

      import_path = relative_import_path(artifact_path)
      header = "<!-- Active mode: #{mode_name}#{mode_version ? " v#{mode_version}" : ''} | source: .kairos/skills/#{mode_name}.md -->"
      region = [
        INSTRUCTION_MODE_MARKER_BEGIN,
        header,
        "@#{import_path}",
        INSTRUCTION_MODE_MARKER_END
      ].join("\n")

      existing = File.exist?(claudemd) ? File.read(claudemd) : ''
      stripped = strip_instruction_mode_region(existing)
      separator = stripped.empty? || stripped.end_with?("\n\n") ? '' : (stripped.end_with?("\n") ? "\n" : "\n\n")
      new_content = stripped + separator + region + "\n"

      atomic_write(claudemd, new_content)
      true
    end

    # Remove the managed marker region from project-root CLAUDE.md if present.
    # Returns true if a region was removed, false otherwise.
    def remove_instruction_mode_region!
      claudemd = claudemd_path
      return false unless File.exist?(claudemd)
      return false unless safe_claudemd_path?(claudemd)

      existing = File.read(claudemd)
      stripped = strip_instruction_mode_region(existing)
      return false if stripped == existing

      atomic_write(claudemd, stripped)
      true
    end

    # Project-root CLAUDE.md absolute path.
    def claudemd_path
      File.join(@project_root, 'CLAUDE.md')
    end

    # Path safety for the host file: must be exactly <project_root>/CLAUDE.md.
    # Distinct from safe_path? (which gates output_root-confined paths).
    def safe_claudemd_path?(path)
      canonical = File.expand_path(path)
      expected = File.expand_path(claudemd_path)
      return true if canonical == expected
      warn "[PluginProjector] WARNING: refusing to mutate non-project CLAUDE.md at '#{path}'"
      false
    end

    # Compute the @-import path used inside the marker region.
    # CLAUDE.md @-imports resolve relative to the project root (where CLAUDE.md lives),
    # so we emit a project-relative path. The artifact lives under output_root,
    # which is .claude/ in :project mode.
    def relative_import_path(artifact_path)
      Pathname.new(artifact_path).relative_path_from(Pathname.new(@project_root)).to_s
    end

    # Remove an existing marker region (and any blank-line padding directly
    # surrounding it) from CLAUDE.md content. Idempotent.
    def strip_instruction_mode_region(content)
      pattern = /\n*#{Regexp.escape(INSTRUCTION_MODE_MARKER_BEGIN)}.*?#{Regexp.escape(INSTRUCTION_MODE_MARKER_END)}\n*/m
      content.sub(pattern, "\n")
    end

    def load_instruction_mode_manifest
      return {} unless File.exist?(@instruction_mode_manifest_path)
      JSON.parse(File.read(@instruction_mode_manifest_path))
    rescue JSON::ParserError
      {}
    end

    def save_instruction_mode_manifest(data)
      FileUtils.mkdir_p(File.dirname(@instruction_mode_manifest_path))
      if data.nil?
        FileUtils.rm_f(@instruction_mode_manifest_path)
      else
        atomic_write(@instruction_mode_manifest_path, JSON.pretty_generate(data))
      end
    end
  end
end
