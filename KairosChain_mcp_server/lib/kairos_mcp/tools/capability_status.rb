# frozen_string_literal: true

require 'json'
require_relative 'base_tool'
require_relative '../capability'

module KairosMcp
  module Tools
    # Phase 1.5 — capability_status MCP tool.
    #
    # Self-articulation surface for KairosChain. Returns a 4-layer view:
    # - declared:          static manifest aggregated from registered tools
    # - observed:          runtime detection of active_harness + used_externals
    # - delivery_channels: harness-delivered content surfaces (CLAUDE.md/MEMORY.md auto-load etc.)
    # - tension:           informational mismatches between declared and observed
    #
    # Each section has its own `tier_used:` annotation honestly reporting which
    # tier of operation produced that data (Acknowledgment invariant).
    #
    # Design reference: docs/drafts/capability_boundary_design_v1.1.md §5
    class CapabilityStatus < BaseTool
      def name
        'capability_status'
      end

      def description
        'Self-articulation of KairosChain capability boundary. Returns declared / observed / delivery_channels / tension layers, each annotated with the tier_used to produce it. Phase 1.5 — addresses Claude Code vs KairosChain feature conflation by making harness dependence explicit.'
      end

      def category
        :guide
      end

      def usecase_tags
        %w[capability harness boundary self-articulation phase1.5 acknowledgment]
      end

      def related_tools
        %w[knowledge_get hello_world]
      end

      # The capability_status tool itself is :core when probe_externals: false
      # (default). The output's external_availability section, when included,
      # is :harness_assisted but is honestly self-labeled in the response.
      def harness_requirement
        :core
      end

      def input_schema
        {
          type: 'object',
          properties: {
            include_observed: {
              type: 'boolean',
              description: 'Include observed (runtime) section. Default: true. When false, observed/tension/external_availability are all omitted.'
            },
            probe_externals: {
              type: 'boolean',
              description: 'Probe external CLI availability via PATH check. Default: false (no probing). When true, external_availability section is added with tier_used: :harness_assisted.'
            },
            probe_versions: {
              type: 'boolean',
              description: 'When probe_externals: true, also fetch each CLI --version via subprocess. Default: false. Adds version field to external_availability entries.'
            },
            filter_tier: {
              type: 'string',
              enum: %w[core harness_assisted harness_specific],
              description: 'Filter declared.tools to only this tier.'
            }
          },
          required: []
        }
      end

      def call(arguments)
        include_observed = arguments.fetch('include_observed', true)
        probe_externals  = arguments.fetch('probe_externals',  false)
        probe_versions   = arguments.fetch('probe_versions',   false)
        filter_tier      = arguments['filter_tier']&.to_sym

        manifest = Capability.aggregate_manifest(@registry)
        declared_section = build_declared_section(manifest, filter_tier)

        result = {
          kairos_version: kairos_version,
          acknowledgment: 'KairosChain capability boundary self-articulation. Each section reports its own tier_used.',
          declared: declared_section,
          delivery_channels: build_delivery_channels_section,
          notes: notes
        }

        if include_observed
          result[:observed] = build_observed_section(manifest, probe_externals, probe_versions)
          result[:tension] = build_tension_section(manifest, result[:observed])
        end

        text_content(JSON.pretty_generate(result))
      rescue StandardError => e
        text_content(JSON.pretty_generate(error: e.message, error_class: e.class.name,
                                          backtrace: e.backtrace&.first(5)))
      end

      private

      def build_declared_section(manifest, filter_tier)
        tools = manifest[:tools]
        tools = tools.select { |t| t[:tier] == filter_tier } if filter_tier
        {
          tier_used: :core,
          summary: manifest[:summary],
          tools: tools,
          declaration_errors: manifest[:declaration_errors]
        }
      end

      def build_observed_section(manifest, probe_externals, probe_versions)
        detection = Capability.detect_harness
        active = detection[:active_harness]
        used = Capability.compute_used_externals(manifest[:tools], active)

        section = {
          active_harness: {
            tier_used: :core,
            value: active,
            detection_method: detection[:detection_method],
            confidence: detection[:confidence]
          },
          used_externals: {
            tier_used: :core,
            value: used[:value],
            same_source_excluded: used[:same_source_excluded],
            acknowledgment: used[:same_source_excluded].any? ?
              "#{used[:same_source_excluded].first} excluded by same-source rule (active_harness=#{active})" :
              'no same-source exclusion applied'
          }
        }

        if probe_externals
          section[:external_availability] = build_external_availability(used[:value], probe_versions)
        end

        section
      end

      def build_external_availability(externals, probe_versions)
        availability = {
          tier_used: :harness_assisted,
          acknowledgment: probe_versions ?
            'this section obtained via local CLI invocation (PATH check + --version subprocess) — NOT a :core operation' :
            'this section obtained via PATH check (filesystem only, no subprocess)'
        }

        externals.each do |ext|
          present = Capability.cli_in_path?(ext)
          entry = { available: present }
          entry[:reason] = 'not found in PATH' unless present
          if present && probe_versions
            ver = Capability.cli_version(ext)
            entry[:version] = ver if ver
          end
          availability[ext] = entry
        end

        availability
      end

      def build_delivery_channels_section
        {
          tier_used: :core,
          acknowledgment: 'these channels deliver content to the LLM but are NOT KairosChain native — content may be KairosChain doctrine, but delivery is a harness feature. tier_used: :core describes that aggregating this manifest is core; it does NOT describe the dependency level of the channels themselves.',
          active: [
            {
              channel: :claude_md_autoload,
              harness: :claude_code,
              content_type: :doctrine,
              example_items: ['Multi-LLM Review Philosophy Briefing'],
              kairoschain_native_content: true,
              kairoschain_native_delivery: false,
              note: 'briefing content is KairosChain doctrine; delivery via Claude Code CLAUDE.md auto-load'
            },
            {
              channel: :memory_md_autoload,
              harness: :claude_code,
              content_type: :context_index,
              example_items: ['Active Resume Points'],
              kairoschain_native_content: true,
              kairoschain_native_delivery: false,
              note: 'memory content is KairosChain L2 handoff data; delivery via Claude Code MEMORY.md auto-load'
            },
            {
              channel: :skill_auto_trigger,
              harness: :claude_code,
              content_type: :skill_invocation,
              kairoschain_native_content: 'depends on skill',
              kairoschain_native_delivery: false,
              note: 'L1 knowledge surfaces as Claude Code Skill; auto-trigger mechanism is harness-specific'
            }
          ]
        }
      end

      def build_tension_section(manifest, observed)
        tensions = []

        # Declaration errors surfaced as tension entries (Partial-failure policy)
        Array(manifest[:declaration_errors]).each do |err|
          tensions << err.merge(
            severity: :declaration_error,
            acknowledgment: 'this tension is informational only; tool may still be invoked (Declare-not-enforce)'
          )
        end

        tensions
      end

      def notes
        [
          'Same-source exclusion rule: active_harness と同源の CLI は used_externals から除外される。',
          'delivery_channels は capability boundary の 4 つ目の articulation 軸 (declared/observed/tension に加えて)。',
          'tier_used は per-section で異なる — capability_status 自身が複数 tier の操作を内包することの honest acknowledgment。',
          'include_observed: false の時、observed / tension / external_availability は省略される (tension は observed の cross-product)。',
          'declared というキー名は top-level section と per-tool field の両方で使われる (静的 manifest と "明示宣言済" boolean)。ネスト深さで判別。',
          'tension entries are informational only — tools are NOT refused at runtime (Declare-not-enforce invariant).'
        ]
      end

      def kairos_version
        if defined?(KairosMcp::VERSION)
          KairosMcp::VERSION
        else
          'unknown'
        end
      end
    end
  end
end
