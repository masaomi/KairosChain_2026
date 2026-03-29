# frozen_string_literal: true

require 'fileutils'
require 'pathname'

module KairosMcp
  module SkillSets
    module DocumentAuthoring
      # Symlink-safe path validation for file writes.
      # Uses File.realpath to resolve symlinks at every ancestor.
      class PathValidator
        ALLOWED_EXTENSIONS = %w[.md .txt].freeze

        # Validate a relative output file path (symlink-safe).
        # @param relative_path [String] user-provided relative path
        # @param base_dir [String] workspace root (from @safety.safe_root)
        # @param allowed_extensions [Array<String>] permitted file extensions
        # @param max_file_size [Integer, nil] max existing file size to overwrite
        # @return [String] validated absolute path
        # @raise [ArgumentError] on invalid path
        def self.validate!(relative_path, base_dir,
                           allowed_extensions: ALLOWED_EXTENSIONS,
                           max_file_size: nil)
          raise ArgumentError, "Empty path" if relative_path.nil? || relative_path.strip.empty?
          raise ArgumentError, "Absolute paths not allowed: #{relative_path}" if relative_path.start_with?('/')

          # Extension whitelist
          ext = File.extname(relative_path).downcase
          unless allowed_extensions.include?(ext)
            raise ArgumentError, "Extension not allowed: #{ext}. Allowed: #{allowed_extensions.join(', ')}"
          end

          # Resolve base_dir to its real path (handles symlinked workspace roots)
          base_real = File.realpath(base_dir)

          # Expand relative_path against the real base (not the possibly-symlinked base_dir)
          expanded = File.expand_path(relative_path, base_real)

          # Containment check on expanded path
          unless expanded.start_with?(base_real + '/')
            raise ArgumentError, "Path escapes workspace: #{relative_path}"
          end

          # Incremental mkdir with per-component symlink check
          parent = File.dirname(expanded)
          safe_mkdir_p(parent, base_real)

          # Check if target itself is a symlink
          if File.symlink?(expanded)
            raise ArgumentError, "Target is a symlink: #{relative_path}"
          end

          # File size guard
          if max_file_size && File.exist?(expanded) && File.size(expanded) > max_file_size
            raise ArgumentError, "Existing file too large (#{File.size(expanded)} bytes > #{max_file_size})"
          end

          expanded
        end

        # Validate a directory path for document_status (read-only).
        # @return [String] validated absolute directory path
        # @raise [ArgumentError] on invalid path
        def self.validate_dir!(relative_path, base_dir)
          raise ArgumentError, "Empty directory path" if relative_path.nil? || relative_path.strip.empty?
          raise ArgumentError, "Absolute paths not allowed: #{relative_path}" if relative_path.start_with?('/')

          base_real = File.realpath(base_dir)
          expanded = File.expand_path(relative_path, base_real)

          unless expanded.start_with?(base_real + '/') || expanded == base_real
            raise ArgumentError, "Path escapes workspace: #{relative_path}"
          end

          # If directory exists, resolve via realpath and re-check containment
          if File.exist?(expanded)
            real = File.realpath(expanded)
            unless real.start_with?(base_real + '/') || real == base_real
              raise ArgumentError, "Symlink escape detected: #{relative_path} resolves to #{real}"
            end
            return real
          end

          expanded
        end

        # Incrementally create directories, checking each component for symlinks.
        # @param target_dir [String] absolute target directory
        # @param base_real [String] realpath of workspace root
        def self.safe_mkdir_p(target_dir, base_real)
          # Decompose the path relative to base_real
          rel = Pathname.new(target_dir).relative_path_from(Pathname.new(base_real))
          parts = rel.each_filename.to_a

          current = base_real
          parts.each do |component|
            current = File.join(current, component)

            if File.symlink?(current)
              raise ArgumentError, "Symlink in path: #{current}"
            end

            if File.exist?(current)
              real = File.realpath(current)
              unless real.start_with?(base_real + '/') || real == base_real
                raise ArgumentError, "Path component escapes workspace: #{current} -> #{real}"
              end
            else
              Dir.mkdir(current)
            end
          end
        end

        private_class_method :safe_mkdir_p
      end
    end
  end
end
