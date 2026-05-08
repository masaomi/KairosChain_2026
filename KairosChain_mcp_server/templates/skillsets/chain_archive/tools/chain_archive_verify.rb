# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module ChainArchive
      module Tools
        # Verifies integrity of all archive segment files.
        class ChainArchiveVerify < KairosMcp::Tools::BaseTool
          def name
            'chain_archive_verify'
          end

          def description
            'Verify integrity of blockchain archive segments. Checks SHA256 hashes of each ' \
            'segment file and validates the internal block chain within each segment.'
          end

          def category
            :chain
          end

          def usecase_tags
            %w[archive verify integrity blockchain audit]
          end

          def related_tools
            %w[chain_archive_run chain_archive_status chain_verify]
          end

          def input_schema
            {
              type: 'object',
              properties: {}
            }
          end

          def call(_arguments)
            archiver = ::KairosMcp::SkillSets::ChainArchive::Archiver.new
            result = archiver.verify_archives

            if result[:segments_verified] == 0
              return text_content("No archive segments found. Nothing to verify.")
            end

            lines = ["Archive Verification Results", "=" * 40]
            result[:segments].each do |seg|
              status = seg[:valid] ? "OK" : "FAIL"
              if seg[:valid]
                lines << "  [#{status}] #{seg[:filename]} (#{seg[:block_count]} blocks)"
              else
                lines << "  [#{status}] #{seg[:filename]}: #{seg[:error]}"
              end
            end
            lines << ""
            lines << "Segments verified: #{result[:segments_verified]}"

            if result[:boundary_checks]&.any?
              failed_boundaries = result[:boundary_checks].reject { |b| b[:valid] }
              if failed_boundaries.any?
                lines << "Boundary check failures:"
                failed_boundaries.each do |bc|
                  lines << "  [FAIL] Segment #{bc[:segment_num]}: #{bc[:error]}"
                end
              end
            end

            overall = result[:valid] ? "All segments valid." : "One or more segments FAILED verification."
            lines << overall

            text_content(lines.join("\n"))
          rescue StandardError => e
            text_content("Error: #{e.message}")
          end
        end
      end
    end
  end
end
