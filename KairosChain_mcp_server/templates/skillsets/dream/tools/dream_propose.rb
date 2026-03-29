# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Dream
      module Tools
        class DreamPropose < KairosMcp::Tools::BaseTool
          def name
            'dream_propose'
          end

          def description
            'Generate actionable promotion proposals from scan candidates. ' \
              'Packages many-to-one L2→L1 synthesis for user review with ready-to-execute commands.'
          end

          def category
            :knowledge
          end

          def usecase_tags
            %w[dream propose promotion synthesis knowledge consolidation]
          end

          def related_tools
            %w[dream_scan dream_archive dream_recall knowledge_update skills_promote]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                candidates: {
                  type: 'array',
                  items: {
                    type: 'object',
                    properties: {
                      target_name: { type: 'string', description: 'Name for the new L1 knowledge entry' },
                      source_sessions: { type: 'array', items: { type: 'string' }, description: 'Session IDs that contributed to this pattern' },
                      source_contexts: { type: 'array', items: { type: 'string' }, description: 'Context names to synthesize' },
                      reason: { type: 'string', description: 'Why this promotion is proposed' }
                    },
                    required: %w[target_name]
                  },
                  description: 'Promotion candidates (from dream_scan or manual selection)'
                },
                content: {
                  type: 'string',
                  description: 'LLM-generated merged content for the new L1 entry. If omitted, a synthesis prompt is returned instead.'
                },
                assembly: {
                  type: 'boolean',
                  description: 'Use Persona Assembly for evaluation. Default: false'
                },
                personas: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Personas for assembly evaluation. Default: ["kairos", "pragmatic"]'
                }
              },
              required: %w[candidates]
            }
          end

          def call(arguments)
            candidates = arguments['candidates'] || []
            return text_content("No candidates provided.") if candidates.empty?

            config = load_dream_config
            proposer = KairosMcp::SkillSets::Dream::Proposer.new(config: config)

            proposals = proposer.propose(
              candidates: candidates,
              content: arguments['content'],
              assembly: arguments.fetch('assembly', false),
              personas: arguments['personas']
            )

            # Record proposal event on blockchain
            record_proposal(candidates, proposals)

            text_content(format_output(proposals))
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, backtrace: e.backtrace&.first(5) }))
          end

          private

          def load_dream_config
            candidates = [
              dream_user_config_path,
              dream_template_config_path
            ].compact

            path = candidates.find { |p| File.exist?(p) }
            return {} unless path

            YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {}
          end

          def dream_user_config_path
            if defined?(KairosMcp) && KairosMcp.respond_to?(:kairos_dir)
              File.join(KairosMcp.kairos_dir, 'skillsets', 'dream', 'config', 'dream.yml')
            else
              File.join(Dir.pwd, '.kairos', 'skillsets', 'dream', 'config', 'dream.yml')
            end
          end

          def dream_template_config_path
            File.expand_path('../../config/dream.yml', __dir__)
          end

          def record_proposal(candidates, proposals)
            return unless defined?(KairosMcp::KairosChain::Chain)

            ready_count = proposals.count { |p| p[:status] == 'ready' }
            needs_content_count = proposals.count { |p| p[:status] == 'needs_content' }

            chain = KairosMcp::KairosChain::Chain.new
            chain.add_block([{
              type: 'dream_proposal',
              candidate_count: candidates.size,
              proposal_count: proposals.size,
              ready_count: ready_count,
              needs_content_count: needs_content_count,
              target_names: proposals.map { |p| p[:target_name] },
              proposed_at: Time.now.utc.iso8601
            }.to_json])
          rescue StandardError => e
            warn "[DreamPropose] Failed to record to blockchain: #{e.message}"
          end

          def format_output(proposals)
            lines = []
            lines << "## Dream Proposals"
            lines << ""
            lines << "**Total**: #{proposals.size} proposal(s)"
            lines << ""

            proposals.each_with_index do |proposal, idx|
              lines << "### Proposal #{idx + 1}: #{proposal[:target_name]}"
              lines << ""
              lines << "**Status**: #{proposal[:status]}"
              lines << "**Reason**: #{proposal[:reason]}"

              if proposal[:source_sessions]&.any?
                lines << "**Source sessions**: #{proposal[:source_sessions].join(', ')}"
              end

              if proposal[:source_contexts]&.any?
                lines << "**Source contexts**: #{proposal[:source_contexts].join(', ')}"
              end

              lines << ""

              if proposal[:command]
                lines << "**Ready command**:"
                lines << "```"
                lines << "#{proposal[:command][:tool]}("
                proposal[:command][:arguments].each do |k, v|
                  display_v = v.is_a?(String) && v.length > 80 ? "#{v[0..77]}..." : v.inspect
                  lines << "  #{k}: #{display_v}"
                end
                lines << ")"
                lines << "```"
              elsif proposal[:synthesis_prompt]
                lines << "**Synthesis prompt** (provide to LLM):"
                lines << "```"
                lines << proposal[:synthesis_prompt].strip
                lines << "```"
                lines << ""
                lines << "**Command template** (fill in content):"
                lines << "```"
                lines << "#{proposal[:command_template][:tool]}("
                proposal[:command_template][:arguments].each do |k, v|
                  lines << "  #{k}: #{v.inspect}"
                end
                lines << ")"
                lines << "```"
              end

              if proposal[:assembly_template]
                lines << ""
                lines << "**Assembly evaluation**:"
                lines << "```"
                lines << "#{proposal[:assembly_template][:tool]}("
                proposal[:assembly_template][:arguments].each do |k, v|
                  lines << "  #{k}: #{v.inspect}"
                end
                lines << ")"
                lines << "```"
              end

              lines << ""
            end

            lines.join("\n")
          end
        end
      end
    end
  end
end
