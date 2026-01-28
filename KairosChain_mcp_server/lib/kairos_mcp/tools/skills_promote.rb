# frozen_string_literal: true

require_relative 'base_tool'
require_relative '../knowledge_provider'
require_relative '../context_manager'
require_relative '../skills_config'

module KairosMcp
  module Tools
    # SkillsPromote: Tool for promoting knowledge between layers with optional Persona Assembly
    #
    # Supports:
    # - L2 → L1: Promote context to knowledge (hash recorded)
    # - L1 → L0: Promote knowledge to meta-skill (requires human approval, full record)
    #
    # When with_assembly=true, generates a structured discussion template
    # using personas defined in L1 knowledge (persona_definitions).
    #
    class SkillsPromote < BaseTool
      VALID_TRANSITIONS = {
        'L2' => ['L1'],
        'L1' => ['L0']
      }.freeze

      DEFAULT_PERSONAS = %w[kairos].freeze

      def name
        'skills_promote'
      end

      def description
        'Promote knowledge between layers (L2→L1, L1→L0) with optional Persona Assembly for decision support. ' \
        'Assembly generates a structured discussion from multiple perspectives before human decision.'
      end

      def category
        :skills
      end

      def usecase_tags
        %w[promote L2 L1 L0 upgrade permanent persona assembly]
      end

      def examples
        [
          {
            title: 'Analyze promotion with Persona Assembly',
            code: 'skills_promote(command: "analyze", source_name: "my_context", from_layer: "L2", to_layer: "L1", session_id: "session_123", personas: ["kairos", "pragmatic"])'
          },
          {
            title: 'Direct promotion L2 to L1',
            code: 'skills_promote(command: "promote", source_name: "validated_idea", from_layer: "L2", to_layer: "L1", session_id: "session_123", reason: "Validated through use")'
          },
          {
            title: 'Check promotion requirements',
            code: 'skills_promote(command: "status", from_layer: "L1", to_layer: "L0")'
          }
        ]
      end

      def related_tools
        %w[context_save knowledge_update skills_evolve skills_audit]
      end

      def input_schema
        {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Command: "analyze" (with assembly), "promote" (direct promotion), or "status" (check promotion requirements)',
              enum: %w[analyze promote status]
            },
            source_name: {
              type: 'string',
              description: 'Name of the source knowledge/context to promote'
            },
            from_layer: {
              type: 'string',
              description: 'Source layer: "L2" or "L1"',
              enum: %w[L2 L1]
            },
            to_layer: {
              type: 'string',
              description: 'Target layer: "L1" or "L0"',
              enum: %w[L1 L0]
            },
            target_name: {
              type: 'string',
              description: 'Name in the target layer (defaults to source_name)'
            },
            reason: {
              type: 'string',
              description: 'Reason for promotion'
            },
            session_id: {
              type: 'string',
              description: 'Session ID (required when from_layer is L2)'
            },
            personas: {
              type: 'array',
              items: { type: 'string' },
              description: 'Personas to use for assembly (default: ["kairos"]). Available: kairos, conservative, radical, pragmatic, optimistic, skeptic'
            },
            assembly_mode: {
              type: 'string',
              description: 'Assembly mode: "oneshot" (default, single evaluation) or "discussion" (multi-round with facilitator)',
              enum: %w[oneshot discussion]
            },
            facilitator: {
              type: 'string',
              description: 'Facilitator persona for discussion mode (default: "kairos")'
            },
            max_rounds: {
              type: 'integer',
              description: 'Maximum discussion rounds for discussion mode (default: 3)'
            },
            consensus_threshold: {
              type: 'number',
              description: 'Consensus threshold for early termination in discussion mode (default: 0.6 = 60%)'
            }
          },
          required: %w[command]
        }
      end

      def call(arguments)
        command = arguments['command']

        case command
        when 'analyze'
          handle_analyze(arguments)
        when 'promote'
          handle_promote(arguments)
        when 'status'
          handle_status(arguments)
        else
          text_content("Unknown command: #{command}")
        end
      end

      private

      # Analyze promotion with Persona Assembly
      def handle_analyze(args)
        validation = validate_promotion_args(args)
        return text_content("Error: #{validation[:error]}") unless validation[:valid]

        source_content = fetch_source_content(args)
        return text_content("Error: #{source_content[:error]}") if source_content[:error]

        personas = args['personas'] || DEFAULT_PERSONAS
        assembly_mode = args['assembly_mode'] || 'oneshot'
        persona_definitions = load_persona_definitions

        if persona_definitions[:error]
          return text_content("Warning: Could not load persona definitions. Using basic analysis.\n\n#{persona_definitions[:error]}")
        end

        generate_assembly_template(
          source_name: args['source_name'],
          source_content: source_content[:content],
          from_layer: args['from_layer'],
          to_layer: args['to_layer'],
          assembly_mode: assembly_mode,
          facilitator: args['facilitator'],
          max_rounds: args['max_rounds'],
          consensus_threshold: args['consensus_threshold'],
          target_name: args['target_name'] || args['source_name'],
          reason: args['reason'],
          personas: personas,
          persona_definitions: persona_definitions[:definitions]
        )
      end

      # Direct promotion without assembly
      def handle_promote(args)
        validation = validate_promotion_args(args)
        return text_content("Error: #{validation[:error]}") unless validation[:valid]

        source_content = fetch_source_content(args)
        return text_content("Error: #{source_content[:error]}") if source_content[:error]

        from_layer = args['from_layer']
        to_layer = args['to_layer']
        target_name = args['target_name'] || args['source_name']
        reason = args['reason'] || "Promoted from #{from_layer} to #{to_layer}"

        case to_layer
        when 'L1'
          promote_to_l1(target_name, source_content[:content], reason)
        when 'L0'
          promote_to_l0(target_name, source_content[:content], reason)
        end
      end

      # Check promotion requirements
      def handle_status(args)
        from_layer = args['from_layer']
        to_layer = args['to_layer']

        output = "## Promotion Status\n\n"

        if from_layer && to_layer
          if valid_transition?(from_layer, to_layer)
            output += "**#{from_layer} → #{to_layer}**: Valid transition\n\n"
            output += promotion_requirements(from_layer, to_layer)
          else
            output += "**#{from_layer} → #{to_layer}**: Invalid transition\n\n"
            output += "Valid transitions:\n"
            output += "- L2 → L1 (Context to Knowledge)\n"
            output += "- L1 → L0 (Knowledge to Meta-skill)\n"
          end
        else
          output += "### Available Transitions\n\n"
          output += "| From | To | Requirements |\n"
          output += "|------|----|--------------|\n"
          output += "| L2 | L1 | Hash reference recorded |\n"
          output += "| L1 | L0 | Human approval required, full blockchain record |\n"
          output += "\n### Persona Assembly\n\n"
          output += "Use `command: \"analyze\"` with `personas` parameter to get multi-perspective evaluation.\n"
          output += "Available personas: kairos, conservative, radical, pragmatic, optimistic, skeptic\n"
        end

        text_content(output)
      end

      def validate_promotion_args(args)
        source_name = args['source_name']
        from_layer = args['from_layer']
        to_layer = args['to_layer']

        return { valid: false, error: 'source_name is required' } unless source_name && !source_name.empty?
        return { valid: false, error: 'from_layer is required' } unless from_layer
        return { valid: false, error: 'to_layer is required' } unless to_layer
        return { valid: false, error: "Invalid transition: #{from_layer} → #{to_layer}" } unless valid_transition?(from_layer, to_layer)

        if from_layer == 'L2'
          session_id = args['session_id']
          return { valid: false, error: 'session_id is required for L2 source' } unless session_id && !session_id.empty?
        end

        { valid: true }
      end

      def valid_transition?(from, to)
        VALID_TRANSITIONS[from]&.include?(to) || false
      end

      def fetch_source_content(args)
        from_layer = args['from_layer']
        source_name = args['source_name']

        case from_layer
        when 'L2'
          session_id = args['session_id']
          manager = ContextManager.new
          context = manager.get(session_id, source_name)
          return { error: "Context '#{source_name}' not found in session '#{session_id}'" } unless context
          { content: context.raw_content, metadata: context.to_h }
        when 'L1'
          provider = KnowledgeProvider.new
          knowledge = provider.get(source_name)
          return { error: "Knowledge '#{source_name}' not found" } unless knowledge
          content = File.read(knowledge.md_file_path)
          { content: content, metadata: knowledge.to_h }
        else
          { error: "Unknown source layer: #{from_layer}" }
        end
      end

      def load_persona_definitions
        provider = KnowledgeProvider.new
        knowledge = provider.get('persona_definitions')

        unless knowledge
          return {
            error: "persona_definitions knowledge not found. Using default personas.",
            definitions: default_persona_definitions
          }
        end

        content = File.read(knowledge.md_file_path)
        { definitions: content }
      rescue StandardError => e
        {
          error: "Failed to load persona definitions: #{e.message}",
          definitions: default_persona_definitions
        }
      end

      def default_persona_definitions
        <<~MD
          ## Default Personas

          ### kairos
          - Role: KairosChain Philosophy Advocate
          - Bias: Favors auditability and constraint preservation
          - Focus: Does this align with Minimum-Nomic principles?
        MD
      end

      def generate_assembly_template(source_name:, source_content:, from_layer:, to_layer:, target_name:, reason:, personas:, persona_definitions:, assembly_mode: 'oneshot', facilitator: nil, max_rounds: nil, consensus_threshold: nil)
        assembly_mode ||= 'oneshot'
        facilitator ||= 'kairos'
        max_rounds ||= 3
        consensus_threshold ||= 0.6
        threshold_percent = (consensus_threshold * 100).to_i

        # Token warning
        warning = generate_token_warning(personas, assembly_mode, max_rounds)

        # Common header
        header = <<~MD
          #{warning}
          ---

          ## Persona Assembly Request

          ### Promotion Proposal

          | Field | Value |
          |-------|-------|
          | **Source** | #{source_name} (#{from_layer}) |
          | **Target** | #{target_name} (#{to_layer}) |
          | **Reason** | #{reason || 'Not specified'} |
          | **Mode** | #{assembly_mode} |

          ### Source Content Preview

          ```
          #{source_content.lines.first(20).join}#{'...(truncated)' if source_content.lines.size > 20}
          ```

          ### Requested Personas

          #{personas.map { |p| "- #{p}" }.join("\n")}

          ---

        MD

        # Mode-specific instructions
        if assembly_mode == 'discussion'
          instructions = <<~MD
            ## Discussion Mode Instructions

            **Facilitator**: #{facilitator}
            **Max rounds**: #{max_rounds}
            **Consensus threshold**: #{threshold_percent}%

            Please conduct a multi-round discussion:

            ### Round 1: Initial Positions

            Each persona states their position on the promotion proposal:
            #{personas.map { |p| "- **#{p}**: [SUPPORT/OPPOSE/NEUTRAL] + rationale" }.join("\n")}

            ### Facilitator (#{facilitator}): Round 1 Summary

            - Summarize agreements and disagreements
            - Identify open concerns
            - Decide: proceed to next round or conclude

            ### Round 2-#{max_rounds}: Address Concerns (if needed)

            - Personas respond to concerns raised
            - Facilitator summarizes after each round
            - End early if #{threshold_percent}%+ consensus reached

            ### Final Summary (by #{facilitator})

            - **Consensus**: [YES / NO / PARTIAL]
            - **Rounds used**: X/#{max_rounds}
            - **Final recommendation**: [PROCEED / DEFER / REJECT]
            - **Key resolutions**: [List]
            - **Unresolved concerns**: [List, if any]

            ---

            ### Persona Reference

            #{extract_persona_summaries(persona_definitions, personas)}

            ---

            *After discussion, use `skills_promote` with `command: "promote"` to execute.*
            *L0 promotions require explicit human approval via `skills_evolve`.*
          MD
        else
          instructions = <<~MD
            ## Oneshot Mode Instructions

            Please evaluate this promotion proposal from each persona's perspective. For each persona, provide:

            ```markdown
            #### [persona_name] ([role])
            - **Position**: [SUPPORT / OPPOSE / NEUTRAL]
            - **Rationale**: [1-2 sentences]
            - **Concerns**: [If any]
            - **Conditions**: [Under which position might change]
            ```

            ### Persona Reference

            #{extract_persona_summaries(persona_definitions, personas)}

            ---

            After completing the persona evaluations, provide:

            ### Consensus Summary

            - **Support count**: X/#{personas.size}
            - **Key concerns**: [List main concerns raised]
            - **Recommendation**: [PROCEED / DEFER / REJECT]

            ---

            *After review, use `skills_promote` with `command: "promote"` to execute.*
            *L0 promotions require explicit human approval via `skills_evolve`.*
          MD
        end

        text_content(header + instructions)
      end

      def generate_token_warning(personas, mode, max_rounds)
        persona_count = personas&.size || 1
        max_rounds ||= 3

        if mode == 'discussion'
          estimated = 500 + (300 * persona_count * max_rounds) + (200 * max_rounds)
          <<~WARNING
            ⚠️ **Persona Assembly: Discussion Mode**

            Estimated tokens: ~#{estimated} (maximum)
            - Base: ~500 tokens
            - Personas × Rounds: ~#{300 * persona_count} × #{max_rounds}
            - Facilitator summaries: ~#{200 * max_rounds}

            For simpler analysis, use `assembly_mode: "oneshot"`.
          WARNING
        else
          estimated = 500 + (300 * persona_count)
          <<~WARNING
            ⚠️ **Persona Assembly: Oneshot Mode**

            Estimated tokens: ~#{estimated}
            - Persona definitions: ~500 tokens
            - Per-persona evaluation: ~300 × #{persona_count}

            For deeper analysis, use `assembly_mode: "discussion"`.
          WARNING
        end
      end

      def extract_persona_summaries(definitions, requested_personas)
        summaries = requested_personas.map do |persona|
          # Extract the section for this persona from definitions
          # Simple regex extraction - looks for ### persona_name section
          pattern = /###\s+#{Regexp.escape(persona)}\s*\n(.*?)(?=\n###|\n---|\z)/mi
          match = definitions.match(pattern)

          if match
            "**#{persona}**:\n#{match[1].strip.lines.first(5).join}"
          else
            "**#{persona}**: (definition not found)"
          end
        end

        summaries.join("\n\n")
      end

      def promote_to_l1(target_name, content, reason)
        unless SkillsConfig.layer_enabled?(:L1)
          return text_content("Error: L1 (knowledge) layer is disabled")
        end

        provider = KnowledgeProvider.new
        existing = provider.get(target_name)

        result = if existing
                   provider.update(target_name, content, reason: "Promotion: #{reason}")
                 else
                   provider.create(target_name, content, reason: "Promotion: #{reason}")
                 end

        if result[:success]
          # Track promotion event for state commit (this triggers auto-commit on promotion)
          track_promotion_change(from_layer: 'L2', to_layer: 'L1', skill_id: target_name, reason: reason)

          action = existing ? 'updated' : 'created'
          output = "## Promotion Successful\n\n"
          output += "**Target**: #{target_name} (L1)\n"
          output += "**Action**: #{action}\n"
          output += "**Hash**: #{result[:next_hash] || result[:hash]}\n\n"
          output += "Change recorded to blockchain (hash reference)."
          text_content(output)
        else
          text_content("Promotion failed: #{result[:error]}")
        end
      end

      def promote_to_l0(target_name, content, reason)
        # L0 promotion requires going through skills_evolve with human approval
        # This method prepares the proposal but doesn't execute it

        title = target_name.to_s.split('_').map(&:capitalize).join(' ')
        
        output = []
        output << "## L0 Promotion Prepared"
        output << ""
        output << "**Important**: L0 changes require human approval and full blockchain recording."
        output << ""
        output << "### Next Steps"
        output << ""
        output << "1. Review the content below"
        output << "2. Use skills_evolve with:"
        output << "   - command: \"add\" (for new skill) or command: \"propose\" (for modification)"
        output << "   - skill_id: \"#{target_name}\""
        output << "   - approved: true (after human review)"
        output << ""
        output << "### Prepared Content"
        output << ""
        output << "The source content has been analyzed. To add as L0 meta-skill, it must be converted to Ruby DSL format."
        output << ""
        output << "**Source content type**: Anthropic Skills format (YAML frontmatter + Markdown)"
        output << ""
        output << "**Required transformation**: Convert to skill :#{target_name} do ... end format"
        output << ""
        output << "### Example L0 Format"
        output << ""
        output << "    skill :#{target_name} do"
        output << "      version \"1.0\""
        output << "      title \"#{title}\""
        output << ""
        output << "      evolve do"
        output << "        allow :content"
        output << "        deny :behavior"
        output << "      end"
        output << ""
        output << "      content <<~CONTENT"
        output << "        # Content from promoted knowledge"
        output << "        ..."
        output << "      CONTENT"
        output << "    end"
        output << ""
        output << "---"
        output << ""
        output << "*L0 promotion is intentionally a manual process to ensure human oversight of meta-rule changes.*"
        output << "*Reason for promotion: #{reason}*"

        text_content(output.join("\n"))
      end

      def promotion_requirements(from_layer, to_layer)
        case [from_layer, to_layer]
        when ['L2', 'L1']
          <<~'MD'
            ### Requirements for L2 → L1

            - Source context must exist
            - L1 layer must be enabled
            - Hash reference will be recorded to blockchain
            - No human approval required

            ### Recommended Personas

            For L2 → L1 promotion: kairos, pragmatic, skeptic
          MD
        when ['L1', 'L0']
          <<~'MD'
            ### Requirements for L1 → L0

            - Source knowledge must exist
            - Content must be converted to Ruby DSL format
            - Human approval required (approved: true)
            - Full transaction recorded to blockchain
            - evolution_enabled: true must be set in config

            ### Recommended Personas

            For L1 → L0 promotion: kairos, conservative, radical, skeptic

            ### Important

            L0 is reserved for Kairos meta-rules only. Ensure the knowledge:
            - Governs KairosChain's own behavior
            - Defines constraints on skill modification
            - Represents mature, validated meta-patterns
          MD
        else
          "Unknown transition requirements."
        end
      end

      # Track promotion event for state commit auto-commit
      def track_promotion_change(from_layer:, to_layer:, skill_id:, reason: nil)
        return unless SkillsConfig.state_commit_enabled?

        require_relative '../state_commit/pending_changes'
        require_relative '../state_commit/commit_service'

        StateCommit::PendingChanges.add(
          layer: to_layer,
          action: 'promote',
          skill_id: skill_id,
          reason: reason,
          metadata: { from_layer: from_layer, to_layer: to_layer }
        )

        # Promotion triggers auto-commit check
        if SkillsConfig.state_commit_auto_enabled?
          service = StateCommit::CommitService.new
          service.check_and_auto_commit
        end
      rescue StandardError => e
        # Log but don't fail if state commit tracking fails
        warn "[SkillsPromote] Failed to track promotion change: #{e.message}"
      end
    end
  end
end
