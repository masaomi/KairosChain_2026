# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # Copy a file; both source and destination must resolve inside workspace.
        class SafeFileCopy < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          def name
            'safe_file_copy'
          end

          def description
            'Copy a file within the workspace. Both source and destination are confined. ' \
              'Returns source hash + destination hash.'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[file copy workspace]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                source: { type: 'string', description: 'Source path (confined)' },
                destination: { type: 'string', description: 'Destination path (confined)' },
                workspace_root: { type: 'string', description: 'Optional override of workspace root' },
                overwrite: { type: 'boolean', description: 'Allow overwriting existing destination (default: false)' },
                create_dirs: { type: 'boolean', description: 'Create destination parent dirs (default: false)' }
              },
              required: %w[source destination]
            }
          end

          def call(arguments)
            ws = resolve_workspace(arguments)
            src = confine(arguments['source'], ws)
            dst = confine(arguments['destination'], ws)

            return json_err("source not a file: #{arguments['source']}") unless File.file?(src)
            return json_err('source and destination are the same path') if src == dst

            overwrite = arguments.fetch('overwrite', false)
            create_dirs = arguments.fetch('create_dirs', false)

            if File.exist?(dst)
              return json_err("destination exists and overwrite=false") unless overwrite
              return json_err('destination is a directory') if File.directory?(dst)
            end

            parent = File.dirname(dst)
            unless File.directory?(parent)
              return json_err("destination parent does not exist: #{parent}") unless create_dirs
              FileUtils.mkdir_p(parent)
            end

            pre_hash_dst = ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement.file_hash(dst)
            FileUtils.cp(src, dst, preserve: false)
            post_hash_dst = ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement.file_hash(dst)
            source_hash = ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement.file_hash(src)

            json_ok(
              source: arguments['source'],
              destination: arguments['destination'],
              source_hash: source_hash,
              pre_hash: pre_hash_dst,
              post_hash: post_hash_dst,
              bytes: File.size(dst)
            )
          rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
            json_err("confinement: #{e.message}")
          rescue StandardError => e
            json_err("copy failed: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
