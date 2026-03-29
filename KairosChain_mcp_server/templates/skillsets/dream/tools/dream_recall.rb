# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Dream
      module Tools
        class DreamRecall < KairosMcp::Tools::BaseTool
          def name
            'dream_recall'
          end

          def description
            'Restore a soft-archived L2 context. Decompresses gzip, verifies SHA256 integrity, ' \
              'restores original .md and subdirectories. Supports preview and verify-only modes.'
          end

          def category
            :knowledge
          end

          def usecase_tags
            %w[dream recall restore decompress verify l2 lifecycle]
          end

          def related_tools
            %w[dream_archive dream_scan dream_propose context_save]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                session_id: {
                  type: 'string',
                  description: 'Session ID of the archived context'
                },
                context_name: {
                  type: 'string',
                  description: 'Name of the archived context'
                },
                preview: {
                  type: 'boolean',
                  description: 'Decompress and display content without restoring. Default: false'
                },
                verify_only: {
                  type: 'boolean',
                  description: 'Check archive integrity without restoring. Default: false'
                }
              },
              required: %w[session_id context_name]
            }
          end

          def call(arguments)
            session_id = arguments['session_id']
            context_name = arguments['context_name']
            preview_mode = arguments.fetch('preview', false)
            verify_only = arguments.fetch('verify_only', false)

            # Safety check — only for mutating operations (not preview/verify)
            unless preview_mode || verify_only
              if @safety && @safety.respond_to?(:can_modify_l2?) && !@safety.can_modify_l2?
                return text_content(JSON.pretty_generate({ error: 'Permission denied: cannot modify L2 contexts' }))
              end
            end

            config = load_dream_config
            archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: config)

            if verify_only
              execute_verify(archiver, session_id, context_name)
            elsif preview_mode
              execute_preview(archiver, session_id, context_name)
            else
              execute_recall(archiver, session_id, context_name)
            end
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, backtrace: e.backtrace&.first(5) }))
          end

          private

          def execute_verify(archiver, session_id, context_name)
            result = archiver.verify(session_id: session_id, context_name: context_name)
            text_content(format_verify_output(result))
          end

          def execute_preview(archiver, session_id, context_name)
            result = archiver.preview(session_id: session_id, context_name: context_name)
            text_content(format_preview_output(result))
          end

          def execute_recall(archiver, session_id, context_name)
            result = archiver.recall_context!(
              session_id: session_id,
              context_name: context_name
            )

            record_recall_event(result)
            text_content(format_recall_output(result))
          end

          def record_recall_event(result)
            return unless defined?(KairosMcp::KairosChain::Chain)

            chain = KairosMcp::KairosChain::Chain.new
            chain.add_block([{
              type: 'dream_recall',
              context_name: result[:context_name],
              session_id: result[:session_id],
              restored_hash: result[:restored_hash],
              restored_size: result[:restored_size],
              verified: result[:verified],
              recalled_at: Time.now.utc.iso8601
            }.to_json])
          rescue StandardError => e
            warn "[DreamRecall] Failed to record to blockchain: #{e.message}"
          end

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

          def format_verify_output(result)
            lines = []
            lines << "## Dream Recall — Integrity Verification"
            lines << ""
            lines << "**Context**: #{result[:context_name]}"
            lines << "**Session**: #{result[:session_id]}"
            lines << "**Status**: #{result[:success] ? 'PASS' : 'FAIL'}"
            lines << ""

            if result[:issues]&.any?
              lines << "### Issues"
              result[:issues].each { |issue| lines << "- #{issue}" }
              lines << ""
            end

            lines << "### Details"
            lines << "- Gzip exists: #{result[:gzip_exists]}"
            lines << "- Archive dir exists: #{result[:archive_dir_exists]}"

            if result[:stub_meta] && !result[:stub_meta].empty?
              meta = result[:stub_meta]
              lines << "- Content hash: `#{meta[:content_hash]}`"
              lines << "- Original size: #{meta[:original_size]} bytes"
              lines << "- Has scripts: #{meta[:has_scripts]}"
              lines << "- Has assets: #{meta[:has_assets]}"
              lines << "- Has references: #{meta[:has_references]}"
            end

            lines.join("\n")
          end

          def format_preview_output(result)
            lines = []
            lines << "## Dream Recall — Preview"
            lines << ""
            lines << "**Context**: #{result[:context_name]}"
            lines << "**Session**: #{result[:session_id]}"
            lines << "**Size**: #{result[:content_size]} bytes"
            lines << "**Hash**: `#{result[:content_hash]}`"
            lines << ""
            lines << "---"
            lines << ""
            lines << result[:content]

            lines.join("\n")
          end

          def format_recall_output(result)
            lines = []
            lines << "## Dream Recall — Restored"
            lines << ""
            lines << "**Context**: #{result[:context_name]}"
            lines << "**Session**: #{result[:session_id]}"
            lines << "**Restored size**: #{result[:restored_size]} bytes"
            lines << "**Hash**: `#{result[:restored_hash]}`"
            lines << "**Verified**: #{result[:verified]}"
            lines << "**Archive preserved**: #{result[:archive_preserved]}"
            lines << ""

            if result[:moved_back]&.any?
              lines << "### Restored subdirectories"
              result[:moved_back].each { |d| lines << "- #{d}/" }
            end

            lines.join("\n")
          end
        end
      end
    end
  end
end
