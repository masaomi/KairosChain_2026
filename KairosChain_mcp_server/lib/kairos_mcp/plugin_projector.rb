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
    # Inline delivery (AGENTS.md) can be truncated by a host's context-file byte cap
    # (e.g. Codex project-doc limit), so warn earlier than the artifact thresholds above.
    INSTRUCTION_MODE_INLINE_WARN  = 32 * 1024

    # Host-specific projection profile (2026-07-02 Codex support; 2026-07-10
    # add-on registration redesign, design v0.3 FROZEN:
    # docs/drafts/multi_host_projection_addon_design_v0.3_FROZEN.md).
    #
    # The core knows exactly one unit of host-specific knowledge — the profile
    # (INV-H1). All host-varying behavior is carried BY the profile as data or
    # callables (INV-H4): `hooks_writer` and `agent_converter` travel with the
    # profile; the engine dispatches only through this abstraction and never
    # branches on a host identity.
    #
    # Profiles enter through a registry (INV-H3/H13). The built-in Claude Code
    # default registers through the same mechanism as every add-on and merely
    # registers first (INV-H2). Additional hosts (codex, opencode, ...) are
    # contributed by add-on SkillSets that declare `host_profiles` files in
    # their skillset.json; `load_addons!` discovers them uniformly for every
    # access path that constructs a projector.
    class HostProfile
      attr_reader :key, :output_subdir, :context_file, :instruction_mode_delivery, :manifest_suffix,
                  :skill_projection, :agents_subdir, :aliases, :requires_host,
                  :hooks_writer, :agent_converter, :reload_hint, :mcp_config_writer

      # Raised when a second registration claims an already-registered host
      # identity from a different source (INV-H13).
      class ConflictError < StandardError; end

      # Raised when a profile declares an out-of-bounds output area or context
      # file — rejected at registration/construction time (INV-H11).
      class InvalidProfile < StandardError; end

      # A safe output subdir is a single relative path segment with no traversal
      # (e.g. '.claude', '.codex'). A safe context file is a bare filename.
      SAFE_OUTPUT_SUBDIR = /\A\.?[a-zA-Z0-9][a-zA-Z0-9._-]*\z/
      SAFE_CONTEXT_FILE  = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/

      # @param skill_projection [Symbol] :own (project skills into this host) or
      #   :reuse_claude (host reads .claude/skills/ directly — skip skill projection).
      # @param agents_subdir [String] subdir under output_root for agents ('agents' or 'agent').
      # @param aliases [Array<String>] alternate lookup keys (e.g. 'claude_code').
      # @param requires_host [String, nil] key of a prerequisite host whose projected
      #   artifacts must exist on disk before this host can project (INV-H5).
      # @param hooks_writer [#call, nil] callable(projector, merged_hooks, outputs)
      #   owning this host's hooks delivery. nil → hooks are not deliverable for
      #   this host and are skipped with a warning.
      # @param agent_converter [#call, nil] callable(content) reshaping an agent
      #   definition into this host's expected frontmatter. nil → verbatim.
      # @param reload_hint [String, nil] host-specific message appended after a
      #   successful projection (e.g. Claude's "/reload-plugins" note). Carried as
      #   profile data so the tool never branches on a host name (INV-H1).
      # @param mcp_config_writer [#call, nil] callable(projector, outputs) that
      #   projects this host's MCP-server connection config (so the host can call
      #   kairos-chain tools). nil → the host manages MCP registration itself.
      #   Travels with the profile (INV-H4).
      # @raise [InvalidProfile] when output_subdir or context_file would escape the
      #   project root (INV-H11): the containment boundary is checked at
      #   registration time, not discovered at projection time.
      def initialize(key:, output_subdir:, context_file:, instruction_mode_delivery:, manifest_suffix:,
                     skill_projection:, agents_subdir:, aliases: [], requires_host: nil,
                     hooks_writer: nil, agent_converter: nil, reload_hint: nil, mcp_config_writer: nil)
        unless output_subdir.is_a?(String) && output_subdir.match?(SAFE_OUTPUT_SUBDIR)
          raise InvalidProfile,
                "host #{key.inspect}: output_subdir #{output_subdir.inspect} is not a single safe relative segment (INV-H11)"
        end
        unless context_file.is_a?(String) && context_file.match?(SAFE_CONTEXT_FILE)
          raise InvalidProfile,
                "host #{key.inspect}: context_file #{context_file.inspect} is not a safe bare filename (INV-H11)"
        end
        @key = key
        @output_subdir = output_subdir
        @context_file = context_file
        @instruction_mode_delivery = instruction_mode_delivery
        @manifest_suffix = manifest_suffix
        @skill_projection = skill_projection
        @agents_subdir = agents_subdir
        @aliases = aliases
        @requires_host = requires_host
        @hooks_writer = hooks_writer
        @agent_converter = agent_converter
        @reload_hint = reload_hint
        @mcp_config_writer = mcp_config_writer
      end

      # Legacy manifest names carry no suffix so existing .kairos/ manifests keep working.
      def manifest_filename(base)
        @manifest_suffix ? "#{base}.#{@manifest_suffix}.json" : "#{base}.json"
      end

      # ---- Registry (INV-H2/H3/H13) -------------------------------------------

      class << self
        # Register a profile. A second registration of an already-owned key from
        # a different source is rejected deterministically (INV-H13). The source
        # of an add-on registration is NOT the profile's self-declared string but
        # the on-disk SkillSet identity established by load_addons! (via
        # @active_load_source), so a squatter reusing a canonical source string
        # cannot silently capture a host key.
        def register(profile, source:)
          effective_source = @active_load_source || source
          registry_entry = registry[profile.key]
          if registry_entry && registry_entry[:source] != effective_source
            raise ConflictError,
                  "host profile #{profile.key.inspect} already registered by #{registry_entry[:source].inspect}; " \
                  "rejecting conflicting registration from #{effective_source.inspect}"
          end
          registry[profile.key] = { profile: profile, source: effective_source }
          profile
        end

        def registered?(key)
          registry.key?(key.to_s)
        end

        # Registered host keys, built-in default first (registration order).
        def available
          registry.keys
        end

        # Resolve a key or alias to a registered profile; nil when absent.
        def lookup(host)
          return host if host.is_a?(HostProfile)
          k = host.to_s
          entry = registry[k]
          return entry[:profile] if entry
          registry.each_value do |e|
            return e[:profile] if e[:profile].aliases.include?(k)
          end
          nil
        end

        # Resolve or fail with an actionable message listing registered hosts.
        def for(host)
          profile = lookup(host)
          return profile if profile
          raise ArgumentError,
                "unknown projection host: #{host.inspect} (registered: #{available.join(', ')}). " \
                'Additional hosts are provided by add-on SkillSets — install the SkillSet ' \
                'for this host into .kairos/skillsets/ and retry.'
        end

        # Discover add-on-contributed profiles under <data_dir>/skillsets/.
        # Any skillset.json may declare `"host_profiles": ["lib/....rb"]`; each
        # file is loaded once and registers its profile(s) through `register`.
        # Malformed or escaping declarations are rejected here — at registration
        # time, not at projection time (INV-H11). Idempotent per data_dir.
        def load_addons!(data_dir)
          return if data_dir.nil?
          dir_key = File.expand_path(data_dir.to_s)
          @loaded_addon_dirs ||= {}
          return if @loaded_addon_dirs[dir_key]
          @loaded_addon_dirs[dir_key] = true

          Dir.glob(File.join(dir_key, 'skillsets', '*', 'skillset.json')).sort.each do |json_path|
            meta = begin
              JSON.parse(File.read(json_path))
            rescue JSON::ParserError, Errno::ENOENT => e
              warn "[HostProfile] WARNING: skipping #{json_path} (unreadable skillset.json: #{e.message})"
              next
            end
            ss_root = File.dirname(json_path)
            # Source is derived from the on-disk SkillSet directory, not from the
            # profile's self-declared string, so provenance is trustworthy (INV-H13).
            load_source = "skillset:#{File.basename(ss_root)}"
            Array(meta['host_profiles']).each do |rel|
              unless contained_realpath?(ss_root, File.join(ss_root, rel.to_s))
                warn "[HostProfile] WARNING: rejecting host_profiles entry #{rel.inspect} in #{json_path} (escapes the SkillSet directory)"
                next
              end
              path = File.expand_path(File.join(ss_root, rel.to_s))
              begin
                @active_load_source = load_source
                require path
              rescue ConflictError => e
                warn "[HostProfile] WARNING: #{e.message}"
              rescue StandardError, LoadError, SyntaxError => e
                warn "[HostProfile] WARNING: failed to load host profile #{path}: #{e.class}: #{e.message}"
              ensure
                @active_load_source = nil
              end
            end
          end
        end

        # True if `path` resolves (following symlinks) to a location at or under
        # the real path of `root`. Rejects symlink escapes that a lexical prefix
        # check would miss (INV-H11). Non-existent paths fall back to lexical
        # containment so an entry naming a not-yet-created file is still bounded.
        def contained_realpath?(root, path)
          root_real = File.realpath(root)
          begin
            target_real = File.realpath(path)
          rescue Errno::ENOENT
            target_real = File.expand_path(path)
          end
          target_real == root_real || target_real.start_with?(root_real + File::SEPARATOR)
        rescue Errno::ENOENT
          false
        end

        # Test seam: forget add-on discovery memoization (profiles stay registered).
        def reset_addon_discovery!
          @loaded_addon_dirs = {}
        end

        # Test seam: clear the registry and re-register only the bundled default.
        # NOTE: the registry is process-global, not scoped per data_dir. This is
        # correct for the single-data_dir deployments (MCP server, CLI): every
        # access path sees one registry (INV-H3). Under a shared-process
        # multi-consumer transport (HTTP/multiuser) an add-on discovered for one
        # data_dir would remain visible to another; per-tenant registry scoping is
        # deferred to the multiuser track and is a precondition for enabling host
        # add-ons there.
        def reset_registry!
          @registry = {}
          @loaded_addon_dirs = {}
          HostProfile.claude_code
        end

        private

        def registry
          @registry ||= {}
        end
      end

      # Claude Code: .claude/ layout, CLAUDE.md with @-import pointer, hooks in
      # settings.json. This is the bundled default — it registers through the
      # same mechanism as every add-on, and merely registers first (INV-H2).
      def self.claude_code
        lookup('claude') || register(
          new(key: 'claude', output_subdir: '.claude', context_file: 'CLAUDE.md',
              instruction_mode_delivery: :import, manifest_suffix: nil,
              skill_projection: :own, agents_subdir: 'agents',
              aliases: %w[claude_code claude-code],
              reload_hint: ' Run /reload-plugins to activate.',
              hooks_writer: ->(projector, merged_hooks, outputs) { projector.write_hooks_to_settings!(merged_hooks, outputs) }),
          source: 'core:bundled_default'
        )
      end
    end
    HostProfile.claude_code # bundled default registers first (INV-H2)

    attr_reader :mode, :project_root, :output_root, :data_dir, :host

    # Construct a PluginProjector.
    #
    # @param project_root [String] consumer project root (where .claude/ and CLAUDE.md live)
    # @param mode [Symbol] :auto, :project, or :plugin
    # @param data_dir [String, nil] KairosChain data directory. When provided, the
    #   projector enforces design v0.2 Inv 3: refuses construction when
    #   real_path(project_root) == real_path(data_dir). When nil, the legacy assumption
    #   data_dir = project_root/.kairos is used for manifest location (backward-compat).
    #
    # @raise [CoincidenceRefused] when project_root and data_dir resolve to the same real path
    def initialize(project_root, mode: :auto, data_dir: nil, host: :claude)
      @project_root = project_root
      @data_dir = data_dir || File.join(project_root, '.kairos')
      enforce_no_coincidence!
      @mode = resolve_mode(mode)
      # Discover add-on host profiles at the single construction choke point so
      # every access path (server, CLI, hooks) sees the same registry (INV-H3).
      HostProfile.load_addons!(@data_dir)
      @host = HostProfile.for(host)
      @output_root = @mode == :plugin ? project_root : File.join(project_root, @host.output_subdir)
      @manifest_path = File.join(@data_dir, @host.manifest_filename('projection_manifest'))
      @instruction_mode_manifest_path = File.join(@data_dir, @host.manifest_filename('instruction_mode_manifest'))
    end

    # Raised when project_root and data_dir resolve to the same real path (design Inv 3).
    class CoincidenceRefused < StandardError
      def initialize(path)
        super("consumer project root and data directory coincide at real path #{path.inspect} (design Inv 3): explicit configuration required")
      end
    end

    # Raised when a host's declared prerequisite (INV-H5) is not satisfied by
    # actual on-disk artifacts — reported pre-flight, before any writes.
    class DependencyUnsatisfied < StandardError; end

    # Main entry: project all SkillSet plugin artifacts + L1 knowledge meta skill
    def project!(enabled_skillsets, knowledge_entries: [])
      enforce_host_dependency!(enabled_skillsets, knowledge_entries)
      previous_manifest = load_manifest
      current_outputs = {}
      merged_hooks = @mode == :plugin ? load_seed_hooks : { 'hooks' => {} }

      # OpenCode reads .claude/skills/ directly (Claude co-use assumption), so it reuses the
      # Claude skill projection instead of duplicating skills into .opencode/skills/.
      reuse_skills = @host.skill_projection == :reuse_claude

      enabled_skillsets.each do |ss|
        next unless ss.has_plugin?

        plugin_dir = File.join(ss.path, 'plugin')
        project_skill!(ss, plugin_dir, current_outputs) unless reuse_skills
        project_agents!(ss, plugin_dir, current_outputs)
        collect_hooks!(ss, plugin_dir, merged_hooks)
      end

      project_knowledge_meta_skill!(knowledge_entries, current_outputs) unless reuse_skills
      write_merged_hooks!(merged_hooks, current_outputs)
      write_host_mcp_config!(current_outputs)
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
      if @host.instruction_mode_delivery == :inline && size > INSTRUCTION_MODE_INLINE_WARN
        warn "[PluginProjector] WARNING: inlining #{size} bytes into #{@host.context_file}; " \
             "host '#{@host.key}' may cap the context-file read (e.g. Codex project-doc byte limit). " \
             "Raise the host's context-file byte cap if the projected mode body appears truncated."
      end

      artifact_path = File.join(@output_root, INSTRUCTION_MODE_REL_PATH)
      raise "instruction mode artifact path outside output_root: #{artifact_path}" unless safe_path?(artifact_path)

      FileUtils.mkdir_p(File.dirname(artifact_path))
      atomic_write(artifact_path, body)

      region_written = merge_instruction_mode_region!(mode_name, mode_version, artifact_path, body)

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
        # Verify against the actual context file, not just the manifest: another host
        # sharing AGENTS.md may have stripped the region since this host projected.
        region_present: context_region_present?,
        projected_at: manifest['projected_at']
      }
    end

    # True if the managed marker region currently exists in this host's context file.
    def context_region_present?
      path = claudemd_path
      return false unless File.exist?(path)
      File.read(path).include?(INSTRUCTION_MODE_MARKER_BEGIN)
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

    # INV-H5 pre-flight: a profile declaring requires_host may only project when
    # the prerequisite profile's projected artifacts actually exist on disk AND
    # verify against their source — registry membership alone is insufficient.
    # "Verify against source" is enforced by comparing the prerequisite's recorded
    # source digest against the digest of the sources being projected now: a
    # prerequisite projected from an older revision of the same sources is stale
    # and rejected. Evaluated before any writes so an unmet requirement is an
    # actionable diagnosis, not a partial failure.
    def enforce_host_dependency!(enabled_skillsets = [], knowledge_entries = [])
      prereq_key = @host.requires_host
      return unless prereq_key

      prereq = HostProfile.lookup(prereq_key)
      raise DependencyUnsatisfied,
            "host '#{@host.key}' requires host '#{prereq_key}', which is not registered" unless prereq

      prereq_manifest_path = File.join(@data_dir, prereq.manifest_filename('projection_manifest'))
      unless File.exist?(prereq_manifest_path)
        raise DependencyUnsatisfied,
              "host '#{@host.key}' requires host '#{prereq_key}' to be projected first " \
              "(no projection manifest at #{prereq_manifest_path}). Project '#{prereq_key}' and retry."
      end

      manifest = begin
        parsed = JSON.parse(File.read(prereq_manifest_path))
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end
      if manifest.nil?
        raise DependencyUnsatisfied,
              "host '#{@host.key}' requires host '#{prereq_key}', but its projection manifest at " \
              "#{prereq_manifest_path} is unreadable or malformed. Re-project '#{prereq_key}' and retry."
      end

      outputs = manifest.fetch('outputs', {})
      missing = outputs.keys.reject { |f| File.exist?(f) }
      unless missing.empty?
        raise DependencyUnsatisfied,
              "host '#{@host.key}' requires host '#{prereq_key}', but #{missing.size} of its projected " \
              "artifact(s) are missing on disk (e.g. #{missing.first}). Re-project '#{prereq_key}' and retry."
      end

      # Verify-against-source: the prerequisite must have been projected from the
      # same source revision now being projected. A digest mismatch means the
      # prerequisite is stale relative to current sources (INV-H5).
      recorded_digest = manifest['source_digest']
      current_digest = compute_source_digest(enabled_skillsets, knowledge_entries)
      return if recorded_digest.nil? || recorded_digest == current_digest
      raise DependencyUnsatisfied,
            "host '#{@host.key}' requires host '#{prereq_key}', whose projection is stale relative to " \
            "the current sources (source digest mismatch). Re-project '#{prereq_key}' and retry."
    end

    # Inv 3 enforcement: refuse if project_root and data_dir resolve to the same
    # real path. Comparison happens post-realpath (design Inv 8). Non-existent
    # paths fall back to expand_path; coincidence at expand_path level still counts.
    def enforce_no_coincidence!
      pr_real = canonicalize(@project_root)
      dd_real = canonicalize(@data_dir)
      return unless pr_real && dd_real && pr_real == dd_real
      raise CoincidenceRefused, pr_real
    end

    def canonicalize(path)
      return nil if path.nil?
      File.realpath(File.expand_path(path))
    rescue Errno::ENOENT
      File.expand_path(path)
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
        target = File.join(@output_root, @host.agents_subdir, "#{ss.name}-#{File.basename(f)}")
        next unless safe_path?(target)
        FileUtils.mkdir_p(File.dirname(target))
        content = File.read(f)
        content = @host.agent_converter.call(content) if @host.agent_converter
        atomic_write(target, content)
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

    # MCP connection config delivery is owned by the profile (INV-H4). Only
    # meaningful in :project mode (plugin mode has no consumer project root to
    # write connection config into).
    def write_host_mcp_config!(outputs)
      return if @mode == :plugin
      return unless @host.mcp_config_writer
      @host.mcp_config_writer.call(self, outputs)
    end

    # Merge a single key into a JSON config file at the project root, preserving
    # all other content, and record it in outputs. `filename` must be a bare
    # filename (no separators) — the write is confined to <project_root>/<filename>
    # (INV-H11). Used by a profile's mcp_config_writer.
    def merge_project_root_json!(filename, top_key, entry_key, entry_value, outputs, output_type)
      raise ArgumentError, "unsafe config filename: #{filename.inspect}" unless filename.match?(HostProfile::SAFE_CONTEXT_FILE)
      path = File.join(@project_root, filename)
      config = load_settings(path) # {} when absent, nil on parse error
      return if config.nil?
      config[top_key] ||= {}
      unless config[top_key].is_a?(Hash)
        warn "[PluginProjector] WARNING: #{filename} '#{top_key}' is not an object; leaving it untouched."
        return
      end
      config[top_key][entry_key] = entry_value
      atomic_write(path, JSON.pretty_generate(config))
      outputs[path] = { 'type' => output_type }
    end

    # Hooks delivery is owned by the profile (INV-H4): the engine dispatches
    # through the profile's hooks_writer and never inspects which host it is.
    def write_merged_hooks!(merged_hooks, outputs)
      if @mode == :plugin
        write_hooks_file!(merged_hooks, outputs)
      elsif @host.hooks_writer
        @host.hooks_writer.call(self, merged_hooks, outputs)
      else
        return if merged_hooks['hooks'].empty?
        warn "[PluginProjector] WARNING: host '#{@host.key}' declares no hooks delivery; " \
             "skipping projection of #{merged_hooks['hooks'].size} hook event(s)."
      end
    end

    # Ensure projected re-projection hooks target THIS host, not the default (claude).
    # Deep-copies so the shared merged_hooks (used by other hosts) is not mutated.
    def rewrite_hook_commands_for_host(merged_hooks)
      copy = JSON.parse(JSON.generate(merged_hooks))
      copy.fetch('hooks', {}).each_value do |handlers|
        next unless handlers.is_a?(Array)
        handlers.each do |h|
          Array(h['hooks']).each do |inner|
            cmd = inner['command']
            next unless cmd.is_a?(String) && cmd.include?('kairos-plugin-project') && !cmd.include?('--host')
            # Insert right after the binary token so compound commands (a && b) stay correct.
            inner['command'] = cmd.sub('kairos-plugin-project', "kairos-plugin-project --host #{@host.key}")
          end
        end
      end
      copy
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
        # Path safety: only delete files under output_root (separator-boundary check)
        unless within_output_root?(f)
          warn "[PluginProjector] WARNING: skipping stale cleanup of '#{f}' (outside output_root)"
          next
        end
        canonical = File.expand_path(f)
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
        File.join(@output_root, @host.agents_subdir)
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

    # True if path is exactly output_root or a descendant. Uses a separator boundary
    # so a sibling like '<root>/.codex_backup' does not match the '<root>/.codex' prefix.
    def within_output_root?(path)
      root = File.expand_path(@output_root)
      canonical = File.expand_path(path)
      canonical == root || canonical.start_with?(root + File::SEPARATOR)
    end

    # Validate target path is under output_root
    def safe_path?(target)
      unless within_output_root?(target)
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
    def merge_instruction_mode_region!(mode_name, mode_version, artifact_path, body)
      claudemd = claudemd_path
      return false unless safe_claudemd_path?(claudemd)

      header = "<!-- Active mode: #{mode_name}#{mode_version ? " v#{mode_version}" : ''} | source: .kairos/skills/#{mode_name}.md -->"
      # Claude Code resolves @-import at session start (pointer). Codex does not,
      # so its body is inlined directly into AGENTS.md.
      payload = case @host.instruction_mode_delivery
                when :inline then body
                else "@#{relative_import_path(artifact_path)}"
                end
      if @host.instruction_mode_delivery == :inline &&
         (body.include?(INSTRUCTION_MODE_MARKER_BEGIN) || body.include?(INSTRUCTION_MODE_MARKER_END))
        warn "[PluginProjector] WARNING: inlined mode body contains an instruction-mode marker; " \
             "re-projection region detection may be unreliable for #{@host.context_file}."
      end
      region = [
        INSTRUCTION_MODE_MARKER_BEGIN,
        header,
        payload,
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

    # Project-root context file absolute path (CLAUDE.md for Claude, AGENTS.md for Codex).
    def claudemd_path
      File.join(@project_root, @host.context_file)
    end

    # Path safety for the host file: must be exactly <project_root>/CLAUDE.md.
    # Distinct from safe_path? (which gates output_root-confined paths).
    def safe_claudemd_path?(path)
      canonical = File.expand_path(path)
      expected = File.expand_path(claudemd_path)
      return true if canonical == expected
      warn "[PluginProjector] WARNING: refusing to mutate non-project #{@host.context_file} at '#{path}'"
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

    # Host-integration API: generic primitives a profile's hooks_writer may use.
    # These carry no host-specific knowledge (INV-H1); making them available to
    # add-on-supplied writers keeps all filesystem effects on the core's single
    # write/delete path (INV-H11).
    public :write_hooks_to_settings!, :load_settings, :rewrite_hook_commands_for_host, :atomic_write,
           :merge_project_root_json!
  end
end
