# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Dream
      class Proposer
        def initialize(config: {})
          @config = config
        end

        # Generate promotion proposals from scan candidates
        # Returns array of proposal objects with ready-to-execute commands
        def propose(candidates:, content: nil, assembly: false, personas: nil)
          candidates.map { |c| build_proposal(c, content: content, assembly: assembly, personas: personas) }
        end

        private

        def build_proposal(candidate, content: nil, assembly: false, personas: nil)
          target_name = candidate['target_name'] || candidate[:target_name]
          source_sessions = candidate['source_sessions'] || candidate[:source_sessions] || []
          source_contexts = candidate['source_contexts'] || candidate[:source_contexts] || []
          reason = candidate['reason'] || candidate[:reason] || "Dream promotion proposal"

          proposal = {
            target_name: target_name,
            source_sessions: source_sessions,
            source_contexts: source_contexts,
            reason: reason
          }

          if content
            # Content provided — generate ready-to-execute command
            proposal[:command] = {
              tool: 'knowledge_update',
              arguments: {
                command: 'create',
                name: target_name,
                content: content,
                reason: "Dream promotion: #{reason}"
              }
            }
            proposal[:status] = 'ready'
          else
            # No content — generate synthesis prompt for LLM
            proposal[:synthesis_prompt] = build_synthesis_prompt(candidate)
            proposal[:command_template] = {
              tool: 'knowledge_update',
              arguments: {
                command: 'create',
                name: target_name,
                content: '<<LLM_GENERATED_CONTENT>>',
                reason: "Dream promotion: #{reason}"
              }
            }
            proposal[:status] = 'needs_content'
          end

          if assembly
            proposal[:assembly_template] = {
              tool: 'skills_promote',
              arguments: {
                command: 'analyze',
                source_name: target_name,
                from_layer: 'L2',
                to_layer: 'L1',
                session_id: source_sessions.first,
                personas: personas || %w[kairos pragmatic]
              }
            }
          end

          proposal
        end

        def build_synthesis_prompt(candidate)
          sources = (candidate['source_contexts'] || candidate[:source_contexts] || []).join(', ')
          <<~PROMPT
            Synthesize the following L2 contexts into a single L1 knowledge entry:

            Source contexts: #{sources}
            Target name: #{candidate['target_name'] || candidate[:target_name]}
            Reason: #{candidate['reason'] || candidate[:reason]}

            Read the source contexts, identify the common pattern, and produce
            a concise, reusable knowledge entry with YAML frontmatter (name,
            description, version, layer: L1, tags).
          PROMPT
        end
      end
    end
  end
end
