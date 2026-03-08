# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module SkillsetCreator
      module Tools
        class ScDesign < KairosMcp::Tools::BaseTool
          def name
            'sc_design'
          end

          def description
            'Analyze requirements to determine whether a capability should be a SkillSet (plugin) ' \
              'or requires KairosChain core changes. Loads core_or_skillset_guide knowledge and applies ' \
              'it to your requirements. Also provides a design phase checklist.'
          end

          def input_schema
            {
              type: 'object',
              properties: {
                command: {
                  type: 'string',
                  enum: %w[analyze checklist],
                  description: 'analyze: determine Core vs SkillSet from requirements. ' \
                               'checklist: show design phase checklist.'
                },
                description: {
                  type: 'string',
                  description: 'What the capability should do (required for analyze)'
                },
                requirements: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Specific requirements to analyze'
                }
              },
              required: %w[command]
            }
          end

          def category
            :meta
          end

          def usecase_tags
            %w[skillset design architecture decision meta]
          end

          def related_tools
            %w[sc_scaffold sc_review kc_evaluate]
          end

          def call(arguments)
            case arguments['command']
            when 'analyze'
              analyze_requirements(arguments)
            when 'checklist'
              show_checklist
            else
              text_content(JSON.pretty_generate({ error: "Unknown command: #{arguments['command']}" }))
            end
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, backtrace: e.backtrace&.first(3) }))
          end

          private

          def analyze_requirements(arguments)
            desc = arguments['description']
            return text_content('Error: description is required for analyze command') unless desc && !desc.empty?

            requirements = arguments['requirements'] || []
            guide_content = load_guide

            prompt = <<~PROMPT
              ## Core-vs-SkillSet Analysis

              ### Capability Description
              #{desc}

              ### Requirements
              #{requirements.empty? ? '(none specified)' : requirements.each_with_index.map { |r, i| "#{i + 1}. #{r}" }.join("\n")}

              ### Decision Guide
              #{guide_content || '(core_or_skillset_guide not available — using built-in criteria)'}

              ### Analysis Task
              For each requirement, determine:

              **What SkillSets CAN do:**
              - Define new MCP tools (BaseTool inheritance via tool_classes)
              - Access KnowledgeProvider, ContextManager, Chain directly
              - Bundle knowledge/ for distribution
              - Register hooks: Safety policies, gates, filters, path resolvers
              - Generate Persona Assembly prompts
              - Read/write to filesystem

              **What requires Core changes:**
              - New tool registration mechanisms
              - Modify SkillSet loading itself
              - New layer types (beyond L0/L1/L2)
              - Change blockchain structure
              - Modify MCP protocol handling
              - Add new built-in extension hooks

              ### Output Format

              #### Decision: SkillSet / Core / Hybrid

              #### Requirement Analysis
              | # | Requirement | Verdict | Reason |
              |---|-------------|---------|--------|

              #### If SkillSet:
              - Suggested tools: [...]
              - Suggested knowledge: [...]
              - Suggested dependencies: [...]

              #### If Core:
              - Affected core files: [...]
              - Scope estimate: [...]
              - Alternative SkillSet approach: [if possible]
            PROMPT

            text_content(prompt)
          end

          def show_checklist
            checklist = <<~CHECKLIST
              ## SkillSet Design Checklist

              ### Architecture
              - [ ] Tool count justified (each tool does something LLM cannot do alone)
              - [ ] Knowledge count justified (each passes discrimination test: base LLM doesn't know this)
              - [ ] Dependencies declared in skillset.json (or runtime-detected if optional)
              - [ ] Config defaults are sensible; config file is not required for basic operation

              ### Tool Design
              - [ ] Each tool has clear input schema with types and descriptions
              - [ ] Each tool's contract clarifies: generates prompts vs. executes actions
              - [ ] Error cases documented and handled with rescue + text_content pattern
              - [ ] Input validation specified (especially for filesystem operations)
              - [ ] Tool inherits from KairosMcp::Tools::BaseTool (not KairosMcp::BaseTool)

              ### Knowledge Design
              - [ ] Frontmatter description includes: What + When + Negative scope
              - [ ] Passes discrimination test: base LLM doesn't know this information
              - [ ] No session-specific content leaks (dates, filenames, user names)
              - [ ] Tags: 5-7, covering domain + function + meta
              - [ ] Version is semver string

              ### Integration
              - [ ] Entry point (lib/{name}.rb) registers knowledge via add_external_dir
              - [ ] Config loading uses SKILLSET_ROOT-relative paths
              - [ ] Multiuser user_context resolution handled (@safety&.current_user)
              - [ ] If depends_on other SkillSets: verified their knowledge is accessible
              - [ ] tool_classes in skillset.json match actual class paths exactly

              ### CLAUDE.md Principles
              - [ ] "Can this be a new SkillSet instead of core bloat?" — Yes
              - [ ] No centralized control introduced
              - [ ] Structural self-referentiality preserved (if applicable)
            CHECKLIST

            text_content(checklist)
          end

          def load_guide
            provider = ::SkillsetCreator.provider(user_context: @safety&.current_user)
            skill = provider.get('core_or_skillset_guide')
            return nil unless skill

            if skill.respond_to?(:md_file_path) && File.exist?(skill.md_file_path)
              File.read(skill.md_file_path, encoding: 'UTF-8')
            elsif skill.respond_to?(:content)
              skill.content
            end
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
