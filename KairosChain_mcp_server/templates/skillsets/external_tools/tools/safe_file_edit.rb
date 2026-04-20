# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # Text-level edit: replace old_string with new_string (atomic write + pre/post hash).
        class SafeFileEdit < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          def name
            'safe_file_edit'
          end

          def description
            'Replace old_string with new_string in a file. Fails if old_string is not found, ' \
              'or occurs more than once (unless replace_all=true). Atomic write; returns pre/post hashes.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[file edit replace atomic hash workspace]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                path: { type: 'string', description: 'File path (relative to workspace or absolute inside it)' },
                old_string: { type: 'string', description: 'Text to find' },
                new_string: { type: 'string', description: 'Replacement text' },
                replace_all: { type: 'boolean', description: 'Replace all occurrences (default: false)' },
                workspace_root: { type: 'string', description: 'Optional override of workspace root' }
              },
              required: %w[path old_string new_string]
            }
          end

          def call(arguments)
            ws = resolve_workspace(arguments)
            abs = confine(arguments['path'], ws)
            return json_err("not a file: #{arguments['path']}") unless File.file?(abs)

            old_s = arguments['old_string'].to_s
            new_s = arguments['new_string'].to_s
            return json_err('old_string must not be empty') if old_s.empty?
            return json_err('old_string == new_string (no-op)') if old_s == new_s

            replace_all = arguments.fetch('replace_all', false)

            pre_hash = ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement.file_hash(abs)
            content = File.binread(abs)
            occurrences = content.scan(old_s).size

            return json_err('old_string not found', occurrences: 0) if occurrences.zero?
            return json_err('old_string not unique (pass replace_all=true to replace all)', occurrences: occurrences) if occurrences > 1 && !replace_all

            new_content = replace_all ? content.gsub(old_s, new_s) : content.sub(old_s, new_s)

            # Atomic write
            parent = File.dirname(abs)
            tmp = File.join(parent, ".#{File.basename(abs)}.tmp.#{SecureRandom.hex(8)}")
            begin
              File.open(tmp, 'wb') do |f|
                f.write(new_content)
                f.flush
                f.fsync rescue nil
              end
              # Preserve mode of original file
              begin
                File.chmod(File.stat(abs).mode, tmp)
              rescue StandardError
                # best-effort
              end
              File.rename(tmp, abs)
            ensure
              File.unlink(tmp) if File.exist?(tmp)
            end

            post_hash = ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement.file_hash(abs)

            json_ok(
              path: arguments['path'],
              absolute_path: abs,
              replacements: replace_all ? occurrences : 1,
              pre_hash: pre_hash,
              post_hash: post_hash,
              changed: pre_hash != post_hash
            )
          rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
            json_err("confinement: #{e.message}")
          rescue StandardError => e
            json_err("edit failed: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
