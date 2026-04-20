# frozen_string_literal: true

require 'digest'

module KairosMcp
  module SkillSets
    module ExternalTools
      # WorkspaceConfinement — path resolution module.
      #
      # Resolves user-supplied paths against a workspace_root such that
      # traversal via ../ segments or symlinks cannot escape the workspace.
      #
      # Security properties:
      #   - Null bytes are rejected outright.
      #   - File.realpath is used to resolve symlinks in the existing prefix,
      #     so any symlink pointing outside workspace_root is detected.
      #   - For non-existent targets (e.g. new file creation), the leading
      #     existing ancestor is realpath-resolved; the trailing non-existent
      #     components are appended verbatim so the confinement check still
      #     applies to the final absolute path.
      #   - Prefix check uses File::SEPARATOR boundary — ".../wsX" is never
      #     accepted as inside ".../ws".
      module WorkspaceConfinement
        class ConfinementError < StandardError; end

        # Resolve `path` against `workspace_root` and return an absolute path
        # guaranteed to be within the workspace. Raises ConfinementError on
        # any escape attempt.
        #
        # @param path [String] user-supplied path (may be relative or absolute)
        # @param workspace_root [String] absolute path to workspace
        # @return [String] resolved absolute path inside workspace
        def self.resolve_path(path, workspace_root)
          raise ConfinementError, 'workspace_root is required' if workspace_root.nil? || workspace_root.to_s.strip.empty?
          raise ConfinementError, 'path is required' if path.nil? || path.to_s.strip.empty?
          raise ConfinementError, 'path contains null byte' if path.to_s.include?("\x00")

          ws = normalize_root(workspace_root)

          candidate = if absolute?(path)
                        path.to_s
                      else
                        File.join(ws, path.to_s)
                      end

          resolved = resolve_with_existing_prefix(candidate)

          unless path_within?(resolved, ws)
            raise ConfinementError, "path escapes workspace: #{path}"
          end

          resolved
        end

        # SHA256 hex digest of content (for WAL pre/post hash fields).
        # Returns nil for nil content.
        def self.content_hash(content)
          return nil if content.nil?
          Digest::SHA256.hexdigest(content)
        end

        # Compute the pre-hash of a file path (or nil if file does not exist).
        # Path must already be confined.
        def self.file_hash(absolute_path)
          return nil unless File.file?(absolute_path)
          Digest::SHA256.file(absolute_path).hexdigest
        end

        def self.normalize_root(workspace_root)
          raise ConfinementError, "workspace_root does not exist: #{workspace_root}" unless File.directory?(workspace_root)
          File.realpath(workspace_root)
        end

        def self.absolute?(path)
          # Ruby's File.absolute_path? is 3.2+. Fall back to portable check.
          if File.respond_to?(:absolute_path?)
            File.absolute_path?(path)
          else
            Pathname.new(path).absolute?
          end
        end

        # Resolve symlinks in any existing prefix of `absolute`, then append
        # remaining non-existent components verbatim.
        def self.resolve_with_existing_prefix(absolute)
          return File.realpath(absolute) if File.exist?(absolute)

          remaining = []
          current = absolute
          loop do
            parent = File.dirname(current)
            if File.exist?(current)
              break
            end
            remaining.unshift(File.basename(current))
            break if parent == current # hit filesystem root
            current = parent
          end

          base = File.exist?(current) ? File.realpath(current) : current
          File.join(base, *remaining)
        end

        def self.path_within?(resolved, ws)
          return true if resolved == ws
          resolved.start_with?(ws + File::SEPARATOR)
        end
      end
    end
  end
end
