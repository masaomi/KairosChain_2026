# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # Atomic file write (tmp + rename) with pre/post sha256 hash for WAL.
        class SafeFileWrite < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          def name
            'safe_file_write'
          end

          def description
            'Atomically write content to a file (tmp + rename). Computes pre/post sha256 hashes ' \
              'for WAL integration. Creates parent directories if create_dirs=true. Confined to workspace_root.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[file write atomic hash workspace wal]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                path: { type: 'string', description: 'Target file path (relative to workspace or absolute inside it)' },
                content: { type: 'string', description: 'Content to write' },
                workspace_root: { type: 'string', description: 'Optional override of workspace root' },
                mode: { type: 'string', description: 'File mode in octal (default: "0644")' },
                encoding: { type: 'string', description: 'Encoding (default: UTF-8)' },
                create_dirs: { type: 'boolean', description: 'Create parent directories if missing (default: false)' },
                overwrite: { type: 'boolean', description: 'Allow overwriting existing file (default: true)' }
              },
              required: %w[path content]
            }
          end

          def call(arguments)
            ws = resolve_workspace(arguments)
            abs = confine(arguments['path'], ws)
            content = arguments['content'].to_s
            overwrite = arguments.fetch('overwrite', true)
            create_dirs = arguments.fetch('create_dirs', false)

            if File.directory?(abs)
              return json_err("target is a directory: #{arguments['path']}")
            end

            pre_hash = ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement.file_hash(abs)
            existed = !pre_hash.nil?
            return json_err("file exists and overwrite=false", path: arguments['path']) if existed && !overwrite

            parent = File.dirname(abs)
            unless File.directory?(parent)
              return json_err("parent directory does not exist: #{parent}") unless create_dirs
              FileUtils.mkdir_p(parent)
            end

            # Write to tmp in same directory, then atomic rename.
            tmp = File.join(parent, ".#{File.basename(abs)}.tmp.#{SecureRandom.hex(8)}")
            begin
              File.open(tmp, 'wb') do |f|
                if arguments['encoding'] == 'binary'
                  f.write(content)
                else
                  f.write(content.dup.force_encoding(arguments['encoding'] || 'UTF-8'))
                end
                f.flush
                f.fsync rescue nil
              end
              if (m = arguments['mode'])
                File.chmod(m.to_i(8), tmp)
              end
              File.rename(tmp, abs)
            ensure
              File.unlink(tmp) if File.exist?(tmp)
            end

            post_hash = ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement.file_hash(abs)

            json_ok(
              path: arguments['path'],
              absolute_path: abs,
              bytes_written: File.size(abs),
              pre_hash: pre_hash,
              post_hash: post_hash,
              existed: existed,
              changed: pre_hash != post_hash
            )
          rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
            json_err("confinement: #{e.message}")
          rescue StandardError => e
            json_err("write failed: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
