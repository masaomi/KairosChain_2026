# frozen_string_literal: true

module KairosMcp
  # Capability module — Phase 1.5 self-articulation infrastructure.
  #
  # Design reference: docs/drafts/capability_boundary_design_v1.1.md
  #
  # Provides:
  # - active_harness detection (env_var first, auto-detect fallback, :unknown honest)
  # - harness_requirement metadata normalization
  # - manifest aggregation across BaseTool subclasses
  #
  # 8 invariants govern this module:
  #   1. Self-articulation     — boundary must be queryable at runtime
  #   2. Honest unknown        — :unknown beats false guess
  #   3. Declare-not-enforce   — articulation only, no runtime gate
  #   4. Structural congruence — DSL matches existing BaseTool method override pattern
  #   5. Composability         — SkillSet tools participate equally
  #   6. Active vs external separation (with same-source exclusion)
  #   7. Forward-only metadata — opt-in, with declared:true/false in manifest
  #   8. Acknowledgment         — runtime dependence is articulated, not silently absorbed
  module Capability
    TIERS = %i[core harness_assisted harness_specific].freeze

    # Mapping from active_harness symbol to its "same-source" CLI name.
    # When active_harness=:claude_code and a tool declares requires_externals: [:claude_cli],
    # claude_cli is excluded from used_externals because it is the SAME source as the
    # harness running KairosChain (active vs external separation invariant).
    SAME_SOURCE_CLI = {
      claude_code: :claude_cli,
      codex_cli:   :codex_cli,
      cursor:      :cursor_cli
    }.freeze

    class << self
      # Returns active_harness detection result. Cached at process boot.
      #
      # @return [Hash] { active_harness:, detection_method:, confidence: }
      def detect_harness
        @detection ||= compute_detection
      end

      # Test-only escape hatch. Production code never calls this.
      def reset!
        @detection = nil
      end

      # Normalize a tool's harness_requirement return value to canonical Hash form.
      # Symbol → { tier: <symbol> }
      # Hash   → validated Hash (raises ArgumentError on violation)
      def normalize_requirement(value)
        hash = case value
               when Symbol then { tier: value }
               when Hash   then deep_symbolize(value)
               else
                 raise ArgumentError, "harness_requirement must be Symbol or Hash, got #{value.class}"
               end

        validate!(hash)
        hash
      end

      # Aggregate harness_requirement declarations across all registered tools.
      # Skip + warn on per-tool validation failure (partial-failure policy).
      #
      # @param registry [KairosMcp::ToolRegistry]
      # @return [Hash] { tools: [...], summary: {...}, declaration_errors: [...] }
      def aggregate_manifest(registry)
        tools_index = registry.instance_variable_get(:@tools) || {}
        sources = registry.instance_variable_get(:@tool_sources) || {}

        entries = []
        errors = []
        summary = Hash.new(0)

        tools_index.each do |name, tool|
          source = sources[name] || :core_tool
          # declared = explicitly overridden in tool subclass (vs inherited BaseTool default)
          declared = tool.method(:harness_requirement).owner != KairosMcp::Tools::BaseTool
          raw = safe_call_requirement(tool)

          begin
            normalized = normalize_requirement(raw)
            entry = { name: name, declared: declared, source: source }.merge(normalized)
            entries << entry
            tier_key = declared ? normalized[:tier] : :"undeclared_default_#{normalized[:tier]}"
            summary[tier_key] += 1
          rescue ArgumentError => e
            errors << { tool: name, issue: "invalid harness_requirement: #{e.message}",
                        severity: :declaration_error }
            entries << { name: name, declared: false, source: source, tier: :unknown,
                         declaration_error: e.message }
            summary[:declaration_errors] += 1
          end
        end

        { tools: entries, summary: summary.transform_values(&:to_i),
          declaration_errors: errors }
      end

      # which-style PATH check using only filesystem (no subprocess).
      # Returns true/false.
      def cli_in_path?(name)
        return false unless name.is_a?(Symbol) || name.is_a?(String)
        bin = name.to_s
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
          full = File.join(dir, bin)
          File.executable?(full) && !File.directory?(full)
        end
      end

      # Get version of a CLI by spawning subprocess (only when probe_versions: true).
      # Returns nil on any failure (Honest unknown).
      def cli_version(name)
        return nil unless cli_in_path?(name)
        out = `#{name} --version 2>&1`.strip
        $?.success? ? out.lines.first&.strip : nil
      rescue StandardError
        nil
      end

      # Compute used_externals from declared manifest entries given active_harness.
      # Applies same-source exclusion rule.
      def compute_used_externals(manifest_entries, active_harness)
        same_source = SAME_SOURCE_CLI[active_harness]
        union = manifest_entries.flat_map { |e| Array(e[:requires_externals]) }.uniq
        excluded = same_source && union.include?(same_source) ? [same_source] : []
        {
          value: union - excluded,
          same_source_excluded: excluded
        }
      end

      private

      def compute_detection
        env = ENV['KAIROS_HARNESS']
        if env && !env.empty?
          if env =~ /\A[A-Za-z0-9_\-]{1,64}\z/
            return { active_harness: env.to_sym, detection_method: :env_var, confidence: :explicit }
          else
            warn "[Capability] KAIROS_HARNESS=#{env.inspect} is malformed; falling back to :unknown"
            return { active_harness: :unknown, detection_method: :none, confidence: :unknown }
          end
        end

        if (auto = auto_detect)
          { active_harness: auto, detection_method: :auto_detect, confidence: :inferred }
        else
          { active_harness: :unknown, detection_method: :none, confidence: :unknown }
        end
      end

      # Auto-detect harness from harness-native signals only.
      # CWD markers (CLAUDE.md, MEMORY.md) are intentionally NOT used because
      # they are project artifacts, not harness signatures (would re-introduce
      # conflation that Phase 1.5 is meant to remove).
      def auto_detect
        # Claude Code sets several env vars when running. Check for any.
        return :claude_code if ENV.keys.any? { |k| k.start_with?('CLAUDE_CODE_') || k == 'CLAUDECODE' }
        # Codex CLI / Cursor specific env vars (heuristic; may be empty in practice).
        return :codex_cli if ENV.key?('CODEX_CLI') || ENV.key?('CODEX_AGENT_ID')
        return :cursor    if ENV.key?('CURSOR_AGENT') || ENV.key?('CURSOR_TRACE_ID')
        nil
      end

      def deep_symbolize(hash)
        hash.each_with_object({}) do |(k, v), out|
          key = k.is_a?(String) ? k.to_sym : k
          out[key] = case v
                     when Hash then deep_symbolize(v)
                     when Array then v.map { |item| item.is_a?(Hash) ? deep_symbolize(item) : item }
                     else v
                     end
        end
      end

      def validate!(hash)
        tier = hash[:tier]
        unless TIERS.include?(tier)
          raise ArgumentError, "tier must be one of #{TIERS.inspect}, got #{tier.inspect}"
        end

        if tier == :harness_specific && hash[:target_harness].nil?
          raise ArgumentError, "harness_specific tier requires :target_harness"
        end

        Array(hash[:requires_harness_features]).each_with_index do |entry, idx|
          unless entry.is_a?(Hash) && entry[:feature] && entry[:target_harness]
            raise ArgumentError, "requires_harness_features[#{idx}] missing :feature or :target_harness"
          end
        end

        Array(hash[:fallback_chain]).each_with_index do |entry, idx|
          unless entry.is_a?(Hash) && entry[:path] && entry[:tier] && entry[:condition]
            raise ArgumentError, "fallback_chain[#{idx}] missing :path/:tier/:condition"
          end
          if entry[:tier] == :harness_specific && entry[:target_harness].nil?
            raise ArgumentError, "fallback_chain[#{idx}] tier=:harness_specific requires :target_harness"
          end
        end

        nil
      end

      def safe_call_requirement(tool)
        tool.harness_requirement
      rescue StandardError => e
        raise ArgumentError, "tool raised during harness_requirement: #{e.message}"
      end
    end

  end
end
