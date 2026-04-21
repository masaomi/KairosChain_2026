# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'digest'
require_relative 'restricted_shell'

module KairosMcp
  class Daemon
    # PdfBuild — generate PDF from markdown via pandoc + xelatex in sandbox.
    #
    # Design (P3.3, Phase 3 v0.2 §4):
    #   Uses RestrictedShell to invoke pandoc with network: :deny.
    #   All work happens in a temp build directory; output is moved to
    #   the target path atomically.
    class PdfBuild
      DEFAULT_TIMEOUT = 120  # seconds
      DEFAULT_ENGINE  = 'xelatex'

      # @param markdown_path [String] absolute path to input markdown
      # @param output_path [String] absolute path for output PDF
      # @param workspace_root [String] workspace root for confinement
      # @param template [String, nil] pandoc template name (optional)
      # @param timeout [Integer] seconds (default 120)
      # @return [Hash] { status:, input_hash:, output_hash:, duration_ms: }
      def self.build(markdown_path:, output_path:, workspace_root:,
                     template: nil, timeout: DEFAULT_TIMEOUT)
        raise ArgumentError, 'markdown_path must be absolute' unless markdown_path.start_with?('/')
        raise ArgumentError, 'output_path must be absolute' unless output_path.start_with?('/')
        raise ArgumentError, 'markdown file not found' unless File.file?(markdown_path)

        input_hash = "sha256:#{Digest::SHA256.file(markdown_path).hexdigest}"

        Dir.mktmpdir('kairos_pdf_build') do |build_dir|
          out_file = File.join(build_dir, 'output.pdf')

          # Build pandoc command
          cmd = ['pandoc', markdown_path, '-o', out_file,
                 "--pdf-engine=#{DEFAULT_ENGINE}",
                 '--pdf-engine-opt=-no-shell-escape']
          cmd += ['--template', template] if template

          result = RestrictedShell.run(
            cmd: cmd,
            cwd: build_dir,
            timeout: timeout,
            allowed_paths: [File.dirname(markdown_path), build_dir, workspace_root],
            network: :deny
          )

          unless result.success?
            return {
              status: 'failed',
              exit_code: result.status,
              stderr: result.stderr[0, 2000],
              input_hash: input_hash,
              duration_ms: result.duration_ms
            }
          end

          unless File.file?(out_file)
            return {
              status: 'failed',
              error: 'pandoc produced no output file',
              input_hash: input_hash,
              duration_ms: result.duration_ms
            }
          end

          # Atomic move to target
          FileUtils.mkdir_p(File.dirname(output_path))
          FileUtils.mv(out_file, output_path)

          output_hash = "sha256:#{Digest::SHA256.file(output_path).hexdigest}"

          {
            status: 'ok',
            input_hash: input_hash,
            output_hash: output_hash,
            output_path: output_path,
            duration_ms: result.duration_ms,
            sandbox_driver: result.sandbox_driver
          }
        end
      end

      # Check if pandoc is available.
      def self.available?
        RestrictedShell::BinaryResolver.resolve!('pandoc')
        true
      rescue RestrictedShell::ResolverError
        false
      end
    end
  end
end
