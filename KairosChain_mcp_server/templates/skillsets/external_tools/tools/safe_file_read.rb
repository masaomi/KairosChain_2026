# frozen_string_literal: true

require 'json'
require_relative '../lib/external_tools'

module KairosMcp
  module SkillSets
    module ExternalTools
      module Tools
        # Read a file confined to the workspace. Returns content + sha256 hash.
        class SafeFileRead < ::KairosMcp::Tools::BaseTool
          include ::KairosMcp::SkillSets::ExternalTools::ToolSupport

          MAX_DEFAULT_BYTES = 5 * 1024 * 1024 # 5 MiB

          def name
            'safe_file_read'
          end

          def description
            'Read a file confined to workspace_root. Returns content, byte size, and sha256 hash. ' \
              'Rejects paths that escape the workspace (via .. or symlinks).'
          end

          def category
            :utility
          end

          def usecase_tags
            %w[file read workspace safe]
          end

          def input_schema
            {
              type: 'object',
              properties: {
                path: { type: 'string', description: 'Path relative to workspace_root (or absolute inside it)' },
                workspace_root: { type: 'string', description: 'Optional override of workspace root' },
                encoding: { type: 'string', description: 'Encoding (default: UTF-8). Use "binary" for raw bytes.' },
                max_bytes: { type: 'integer', description: "Maximum bytes to read (default: #{MAX_DEFAULT_BYTES})" }
              },
              required: ['path']
            }
          end

          def call(arguments)
            ws = resolve_workspace(arguments)
            abs = confine(arguments['path'], ws)
            return json_err("not a file: #{arguments['path']}") unless File.file?(abs)

            max_bytes = (arguments['max_bytes'] || MAX_DEFAULT_BYTES).to_i
            size = File.size(abs)
            return json_err("file exceeds max_bytes (#{size} > #{max_bytes})", size: size, max_bytes: max_bytes) if size > max_bytes

            encoding = arguments['encoding'] || 'UTF-8'
            mode = encoding == 'binary' ? 'rb' : 'r'
            content = File.open(abs, mode) { |f| f.read }
            content.force_encoding(encoding) unless encoding == 'binary'

            json_ok(
              path: relative_to(abs, ws),
              absolute_path: abs,
              size: size,
              sha256: ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement.file_hash(abs),
              encoding: encoding,
              content: content
            )
          rescue ::KairosMcp::SkillSets::ExternalTools::WorkspaceConfinement::ConfinementError => e
            json_err("confinement: #{e.message}")
          rescue StandardError => e
            json_err("read failed: #{e.class}: #{e.message}")
          end

          private

          def relative_to(abs, ws)
            return abs unless abs.start_with?(ws)
            rel = abs.sub(ws, '')
            rel.sub(%r{^/}, '')
          end
        end
      end
    end
  end
end
