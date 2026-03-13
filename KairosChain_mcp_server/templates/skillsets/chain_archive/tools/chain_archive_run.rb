# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module ChainArchive
      module Tools
        # Triggers blockchain archiving. Archives all live blocks into a
        # compressed segment file and replaces the live chain with a checkpoint block.
        class ChainArchiveRun < KairosMcp::Tools::BaseTool
          def name
            'chain_archive_run'
          end

          def description
            'Archive old blockchain blocks to a compressed segment file. ' \
            'When the live chain exceeds the threshold, all blocks are compressed ' \
            'to storage/archives/segment_NNNNNN.json.gz and the live chain is ' \
            'replaced with a single checkpoint block. The full audit trail is preserved.'
          end

          def category
            :chain
          end

          def usecase_tags
            %w[archive prune blockchain storage maintenance]
          end

          def related_tools
            %w[chain_archive_status chain_archive_verify chain_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                reason: {
                  type: 'string',
                  description: 'Optional reason for archiving (recorded in the checkpoint block and manifest)'
                },
                threshold: {
                  type: 'integer',
                  description: "Override the default archive threshold (default: #{::KairosMcp::SkillSets::ChainArchive::Archiver::DEFAULT_THRESHOLD} blocks)"
                },
                force: {
                  type: 'boolean',
                  description: 'Force archive even if below threshold (sets threshold to 0)'
                }
              }
            }
          end

          def call(arguments)
            threshold = arguments['force'] ? 0 : arguments['threshold']
            reason    = arguments['reason']

            archiver = ::KairosMcp::SkillSets::ChainArchive::Archiver.new
            result   = archiver.archive!(reason: reason, threshold: threshold)

            if result[:skipped]
              text_content("Archive skipped: #{result[:reason]}")
            elsif result[:success]
              text_content(<<~MSG)
                Archive completed successfully.

                  Blocks archived:      #{result[:blocks_archived]}
                  Segment file:         #{result[:segment_filename]}
                  Segment SHA256:       #{result[:segment_hash]}
                  New live chain size:  #{result[:new_live_chain_length]}
                  Archive block hash:   #{result[:archive_block_hash]}

                The live chain now starts from the archive block.
                Use chain_archive_verify to confirm archive integrity.
              MSG
            else
              text_content("Archive failed: #{result[:error] || 'unknown error'}")
            end
          rescue StandardError => e
            text_content("Error: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
          end
        end
      end
    end
  end
end
