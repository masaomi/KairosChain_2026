# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module ChainArchive
      module Tools
        # Reports the current archive state: live chain size, segment count, totals.
        class ChainArchiveStatus < KairosMcp::Tools::BaseTool
          def name
            'chain_archive_status'
          end

          def description
            'Show blockchain archive status: live chain block count, number of archive segments, ' \
            'total blocks across live + archives, and whether archiving is recommended.'
          end

          def category
            :chain
          end

          def usecase_tags
            %w[archive status blockchain storage]
          end

          def related_tools
            %w[chain_archive_run chain_archive_verify chain_status]
          end

          def input_schema
            {
              type: 'object',
              properties: {}
            }
          end

          def call(_arguments)
            archiver = ::KairosMcp::SkillSets::ChainArchive::Archiver.new
            s = archiver.status

            recommendation = if s[:should_archive]
              "  *** Live chain exceeds threshold — run chain_archive_run to prune ***"
            else
              "  Live chain is within threshold — no action needed."
            end

            text_content(<<~MSG)
              Blockchain Archive Status
              =========================
              Live chain blocks:        #{s[:live_block_count]}
              Archive segments:         #{s[:archive_segment_count]}
              Total archived blocks:    #{s[:total_archived_blocks]}
              Total blocks (all time):  #{s[:total_blocks]}
              Archive threshold:        #{s[:threshold]}
              Archives directory:       #{s[:archives_dir]}

              #{recommendation}
            MSG
          rescue StandardError => e
            text_content("Error: #{e.message}")
          end
        end
      end
    end
  end
end
