# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module Dream
      module Tools
        class DreamArchive < KairosMcp::Tools::BaseTool
          def name
            'dream_archive'
          end

          def description
            'Soft-archive stale L2 contexts. Compresses full text to gzip, moves subdirs to archive, ' \
              'and leaves a searchable stub. Use dream_recall to restore. Default: dry_run (preview only).'
          end

          def category
            :knowledge
          end

          def usecase_tags
            %w[dream archive compress stub l2 lifecycle cleanup]
          end

          def related_tools
            %w[dream_scan dream_recall dream_propose context_save]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                targets: {
                  type: 'array',
                  items: {
                    type: 'object',
                    properties: {
                      session_id: { type: 'string', description: 'Session ID' },
                      context_name: { type: 'string', description: 'Context name' }
                    },
                    required: %w[session_id context_name]
                  },
                  description: 'Array of archive targets. Each must have session_id and context_name.'
                },
                summary: {
                  type: 'string',
                  description: 'Caller-provided summary text for the stub. The calling LLM should generate this.'
                },
                dry_run: {
                  type: 'boolean',
                  description: 'Preview only — do not actually archive. Default: true (safe by default).'
                }
              },
              required: %w[targets summary]
            }
          end

          def call(arguments)
            # Safety check
            if @safety && @safety.respond_to?(:can_modify_l2?) && !@safety.can_modify_l2?
              return text_content(JSON.pretty_generate({ error: 'Permission denied: cannot modify L2 contexts' }))
            end

            targets = arguments['targets'] || []
            summary = arguments['summary']
            dry_run = arguments.fetch('dry_run', true)

            return text_content(JSON.pretty_generate({ error: 'No targets provided' })) if targets.empty?
            return text_content(JSON.pretty_generate({ error: 'Summary is required' })) unless summary && !summary.strip.empty?

            config = load_dream_config
            archiver = KairosMcp::SkillSets::Dream::Archiver.new(config: config)

            if dry_run
              execute_dry_run(archiver, targets, summary)
            else
              execute_archive(archiver, targets, summary)
            end
          rescue StandardError => e
            text_content(JSON.pretty_generate({ error: e.message, backtrace: e.backtrace&.first(5) }))
          end

          private

          def execute_dry_run(archiver, targets, summary)
            items = targets.map do |t|
              sid = t['session_id']
              cname = t['context_name']

              if archiver.archived?(session_id: sid, context_name: cname)
                { name: cname, session: sid, status: 'skipped', reason: 'already archived' }
              else
                # Validate target exists before claiming "would_archive"
                ctx_dir = archiver.send(:context_dir_path, sid, cname)
                md_file = File.join(ctx_dir, "#{cname}.md")
                if File.exist?(md_file)
                  { name: cname, session: sid, status: 'would_archive', summary_preview: summary.slice(0, 200) }
                else
                  { name: cname, session: sid, status: 'error', reason: 'context not found' }
                end
              end
            end

            text_content(format_dry_run_output(items))
          end

          def execute_archive(archiver, targets, summary)
            items = []
            archived_count = 0
            skipped_count = 0
            total_bytes_saved = 0

            targets.each do |t|
              sid = t['session_id']
              cname = t['context_name']

              begin
                result = archiver.archive_context!(
                  session_id: sid,
                  context_name: cname,
                  summary: summary
                )

                record_archive_event(result)

                bytes_saved = result[:original_size] - result[:stub_size]
                total_bytes_saved += bytes_saved
                archived_count += 1

                items << {
                  name: cname,
                  session: sid,
                  original_size: result[:original_size],
                  content_hash: result[:content_hash],
                  stub_size: result[:stub_size],
                  moved_subdirs: result[:moved_subdirs],
                  verified: result[:verified]
                }
              rescue StandardError => e
                skipped_count += 1
                items << { name: cname, session: sid, status: 'error', error: e.message }
              end
            end

            output = {
              archived: archived_count,
              skipped: skipped_count,
              total_bytes_saved: total_bytes_saved,
              items: items
            }

            text_content(format_archive_output(output))
          end

          def record_archive_event(result)
            return unless defined?(KairosMcp::KairosChain::Chain)

            chain = KairosMcp::KairosChain::Chain.new
            chain.add_block([{
              type: 'dream_archive',
              context_name: result[:context_name],
              session_id: result[:session_id],
              content_hash: result[:content_hash],
              original_size: result[:original_size],
              stub_size: result[:stub_size],
              moved_subdirs: result[:moved_subdirs],
              archived_at: Time.now.utc.iso8601
            }.to_json])
          rescue StandardError => e
            warn "[DreamArchive] Failed to record to blockchain: #{e.message}"
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

          def format_dry_run_output(items)
            lines = []
            lines << "## Dream Archive — Dry Run"
            lines << ""
            lines << "**Mode**: Preview only (set `dry_run: false` to execute)"
            lines << ""

            items.each do |item|
              if item[:status] == 'skipped'
                lines << "- **#{item[:name]}** (#{item[:session]}): SKIPPED — #{item[:reason]}"
              else
                lines << "- **#{item[:name]}** (#{item[:session]}): Would archive"
                lines << "  - Summary: #{item[:summary_preview]}"
              end
            end

            lines.join("\n")
          end

          def format_archive_output(output)
            lines = []
            lines << "## Dream Archive Results"
            lines << ""
            lines << "**Archived**: #{output[:archived]}"
            lines << "**Skipped**: #{output[:skipped]}"
            lines << "**Total bytes saved**: #{output[:total_bytes_saved]}"
            lines << ""

            output[:items].each do |item|
              if item[:status] == 'error'
                lines << "- **#{item[:name]}** (#{item[:session]}): ERROR — #{item[:error]}"
              else
                lines << "- **#{item[:name]}** (#{item[:session]})"
                lines << "  - Original: #{item[:original_size]} bytes, Stub: #{item[:stub_size]} bytes"
                lines << "  - Hash: `#{item[:content_hash]}`"
                lines << "  - Moved: #{item[:moved_subdirs]&.join(', ') || 'none'}"
                lines << "  - Verified: #{item[:verified]}"
              end
            end

            lines.join("\n")
          end
        end
      end
    end
  end
end
