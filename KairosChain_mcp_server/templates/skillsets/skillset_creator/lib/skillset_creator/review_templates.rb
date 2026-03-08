# frozen_string_literal: true

module SkillsetCreator
  # Generates structured review prompts for multi-LLM and Persona Assembly review.
  # These templates are self-contained prompts to copy to other AI apps (multi_llm mode)
  # or structured prompts for same-session evaluation (persona_assembly mode).
  module ReviewTemplates
    module_function

    REVIEW_PERSONAS = {
      'kairos' => {
        role: 'Philosophy Alignment Reviewer',
        focus: 'Does this align with KairosChain principles? Is self-referentiality genuine or decorative?'
      },
      'pragmatic' => {
        role: 'Implementation Feasibility Assessor',
        focus: 'Is this practically implementable? Does each tool add value beyond natural LLM conversation?'
      },
      'skeptic' => {
        role: 'Risk and Over-engineering Detector',
        focus: 'What could go wrong? Is this over-engineered? What would a simpler alternative look like?'
      }
    }.freeze

    DESIGN_FOCUS_AREAS = [
      'Is this correctly classified as SkillSet (not requiring core changes)?',
      'Are the tool interfaces well-designed? (Input schemas, error cases, contracts)',
      'Is the bundled knowledge appropriate for L1? (Passes discrimination test?)',
      'Are there missing edge cases or implementation risks?',
      'Does the design align with KairosChain philosophy?'
    ].freeze

    IMPLEMENTATION_FOCUS_AREAS = [
      'Does the implementation match the design document?',
      'Are tools correctly inheriting from KairosMcp::Tools::BaseTool?',
      'Is knowledge registered via add_external_dir in the entry point?',
      'Is input validation adequate? (especially filesystem operations)',
      'Are error cases handled with rescue + text_content pattern?',
      'Is multiuser context (user_context) properly resolved?'
    ].freeze

    CLAUDE_MD_PRINCIPLES = <<~PRINCIPLES
      ## KairosChain Core Principles (from CLAUDE.md)
      - Is this change meta-level or base-level? Be explicit about layer boundaries.
      - Does this preserve structural self-referentiality?
      - Does this introduce centralized control? Prefer locally-autonomous designs.
      - Can this be a new SkillSet instead of core bloat?
      - Is the change recorded? L0 changes must be fully recorded on the blockchain.
    PRINCIPLES

    def design_review_multi_llm(document_content:, focus_areas: nil, include_claude_md: true)
      areas = focus_areas || DESIGN_FOCUS_AREAS

      <<~PROMPT
        ## SkillSet Design Review Request

        ### Context
        You are reviewing a KairosChain SkillSet design document.
        KairosChain is a self-referential knowledge management system with
        L0 (meta-rules) / L1 (knowledge) / L2 (context) layer architecture.
        SkillSets are plugins that add MCP tools without modifying core code.

        #{include_claude_md ? CLAUDE_MD_PRINCIPLES : ''}

        ### Design Document
        #{document_content}

        ### Review Focus Areas
        #{areas.each_with_index.map { |area, i| "#{i + 1}. #{area}" }.join("\n")}

        ### Expected Feedback Format
        For each focus area:
        - **Assessment**: GOOD / CONCERN / ISSUE
        - **Rationale**: 1-2 sentences with specific evidence
        - **Suggestion**: If applicable

        ### Overall Recommendation
        - [ ] **APPROVE** — Ready for implementation
        - [ ] **REVISE** — Minor changes needed (list specific items)
        - [ ] **REDESIGN** — Major concerns (explain why)
      PROMPT
    end

    def design_review_persona_assembly(document_content:, personas: nil, focus_areas: nil)
      persona_names = personas || %w[kairos pragmatic skeptic]
      persona_defs = persona_names.map { |p| REVIEW_PERSONAS[p] || { role: p, focus: 'General review' } }
      areas = focus_areas || DESIGN_FOCUS_AREAS

      <<~PROMPT
        ## Persona Assembly: SkillSet Design Review

        ### Evaluation Task
        Evaluate the following SkillSet design from multiple perspectives.

        ### Personas
        #{persona_names.each_with_index.map { |name, i|
          d = persona_defs[i]
          "- **#{name}** (#{d[:role]}): #{d[:focus]}"
        }.join("\n")}

        ### Design Document
        #{document_content}

        ### Evaluation Dimensions
        #{areas.each_with_index.map { |area, i| "#{i + 1}. #{area}" }.join("\n")}

        ### Output Format
        Per persona, per dimension: **PASS** / **CONCERN** / **FAIL** with evidence.

        #### Summary
        **Recommendation**: APPROVE / REVISE / REDESIGN with specific action items.
      PROMPT
    end

    def implementation_review_multi_llm(file_listing:, key_files_content:, focus_areas: nil, include_claude_md: true)
      areas = focus_areas || IMPLEMENTATION_FOCUS_AREAS

      <<~PROMPT
        ## SkillSet Implementation Review Request

        ### Context
        You are reviewing a KairosChain SkillSet implementation.
        KairosChain is a self-referential knowledge management system.
        SkillSets are plugins that add MCP tools without modifying core code.
        Tools inherit from KairosMcp::Tools::BaseTool and implement: name, description, input_schema, call.

        #{include_claude_md ? CLAUDE_MD_PRINCIPLES : ''}

        ### File Listing
        ```
        #{file_listing}
        ```

        ### Key Files
        #{key_files_content}

        ### Review Focus Areas
        #{areas.each_with_index.map { |area, i| "#{i + 1}. #{area}" }.join("\n")}

        ### Expected Feedback Format
        For each focus area:
        - **Assessment**: GOOD / CONCERN / ISSUE
        - **Rationale**: 1-2 sentences with specific evidence
        - **Suggestion**: If applicable

        ### Overall Recommendation
        - [ ] **APPROVE** — Ready to commit
        - [ ] **REVISE** — Issues to fix (list them)
        - [ ] **REWORK** — Significant problems (explain)
      PROMPT
    end

    def implementation_review_persona_assembly(file_listing:, key_files_content:, personas: nil, focus_areas: nil)
      persona_names = personas || %w[kairos pragmatic skeptic]
      persona_defs = persona_names.map { |p| REVIEW_PERSONAS[p] || { role: p, focus: 'General review' } }
      areas = focus_areas || IMPLEMENTATION_FOCUS_AREAS

      <<~PROMPT
        ## Persona Assembly: SkillSet Implementation Review

        ### Personas
        #{persona_names.each_with_index.map { |name, i|
          d = persona_defs[i]
          "- **#{name}** (#{d[:role]}): #{d[:focus]}"
        }.join("\n")}

        ### File Listing
        ```
        #{file_listing}
        ```

        ### Key Files
        #{key_files_content}

        ### Evaluation Dimensions
        #{areas.each_with_index.map { |area, i| "#{i + 1}. #{area}" }.join("\n")}

        ### Output Format
        Per persona, per dimension: **PASS** / **CONCERN** / **FAIL** with evidence.

        #### Summary
        **Recommendation**: APPROVE / REVISE / REWORK with specific action items.
      PROMPT
    end

    # File priority for implementation review (Antigravity N2)
    FILE_PRIORITY = [
      { pattern: 'skillset.json', priority: 1, include: :full },
      { pattern: 'tools/*.rb', priority: 2, include: :full },
      { pattern: 'lib/*.rb', priority: 3, include: :full },
      { pattern: 'config/*.yml', priority: 4, include: :full },
      { pattern: 'knowledge/**/*.md', priority: 5, include: :frontmatter_plus_50 }
    ].freeze

    def collect_key_files(skillset_dir, max_chars: 30_000)
      collected = []
      total_chars = 0

      FILE_PRIORITY.each do |spec|
        files = Dir[File.join(skillset_dir, spec[:pattern])].sort
        files.each do |file|
          break if total_chars > max_chars

          content = File.read(file, encoding: 'UTF-8')
          relative = file.sub("#{skillset_dir}/", '')

          display_content = case spec[:include]
                            when :full
                              content
                            when :frontmatter_plus_50
                              lines = content.lines
                              lines.first(50).join
                            end

          total_chars += display_content.length
          collected << "### #{relative}\n```\n#{display_content}\n```"
        end
      end

      collected.join("\n\n")
    end
  end
end
