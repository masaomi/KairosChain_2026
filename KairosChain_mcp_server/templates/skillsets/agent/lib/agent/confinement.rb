# frozen_string_literal: true

require 'fileutils'

module KairosMcp
  module SkillSets
    module Agent
      # Confinement — AGT-1/AGT-2 substrate-level enforcement for the delegated
      # act route (guard track design v0.3.1 FROZEN).
      #
      # Ruby port of the mechanism proven by the external track's
      # kairos_confine.py (7 validated sandbox-exec spikes): macOS
      # `sandbox-exec -p` SBPL profile with (allow default) + (deny file-write*)
      # + write-allowlist, plus a targeted read deny of the stores (AGT-2).
      #
      # Fail-closed preconditions (all raise ConfinementError):
      # - every embedded path is realpath-resolved before it enters the profile.
      #   An unresolved deny silently no-ops on macOS (/tmp -> /private/tmp),
      #   which is fail-open; an unresolved allowlist admits a symlink escape.
      # - the scratch area is realpath-disjoint from the stores, the live
      #   project tree, and the agent SkillSet's own code (AGT-1 disjointness
      #   is required, not presumed — the declaration is downstream of a model
      #   decision).
      module Confinement
        class ConfinementError < StandardError; end

        module_function

        # Resolve to a canonical physical path or fail closed.
        def realpath_strict(path, what = 'path')
          raise ConfinementError, "#{what} is nil/empty" if path.nil? || path.to_s.empty?

          real = File.realpath(path)
          raise ConfinementError, "#{what} does not resolve absolutely: #{path}" unless real.start_with?('/')

          real
        rescue Errno::ENOENT, Errno::EACCES => e
          raise ConfinementError, "#{what} not resolvable (#{e.class}): #{path}"
        end

        def within?(inner, outer)
          inner == outer || inner.start_with?("#{outer}/")
        end

        # Paths a confined executor must never write (and, for the stores,
        # never read). Resolved lazily so tests can point KairosMcp.data_dir
        # at a tmpdir.
        def trust_paths(project_root)
          root = realpath_strict(project_root, 'project_root')
          stores = File.join(root, '.kairos')
          skillset_dir = File.expand_path('../..', __dir__)
          [root, stores, skillset_dir].map { |p| File.exist?(p) ? realpath_strict(p, p) : p }.uniq
        end

        # AGT-1: the declared scratch area must be structurally disjoint from
        # the protected surface. Overlap is a guard failure, not a warning.
        def assert_disjoint!(scratch_dir, project_root)
          scratch = realpath_strict(scratch_dir, 'scratch_dir')
          trust_paths(project_root).each do |t|
            next unless within?(scratch, t) || within?(t, scratch)

            raise ConfinementError,
                  "scratch area overlaps protected surface: #{scratch} vs #{t} (AGT-1 disjointness)"
          end
          scratch
        end

        # SBPL profile: default-allow (the executor must reach its provider and
        # the system runtime), write-deny everywhere except the scratch area,
        # read-deny targeted at the stores (AGT-2: the stores are outside the
        # executor's readable surface; broad read confinement is Slice 2+
        # territory, the invariant names only the stores).
        def profile(scratch_dir, stores_dir)
          scratch = realpath_strict(scratch_dir, 'scratch_dir')
          stores = realpath_strict(stores_dir, 'stores_dir')
          raise ConfinementError, 'scratch inside stores' if within?(scratch, stores) || within?(stores, scratch)

          <<~SBPL
            (version 1)
            (allow default)
            (deny file-write*)
            (allow file-write* (subpath "#{scratch}"))
            (allow file-write* (subpath "/dev"))
            (deny file-read* (subpath "#{stores}"))
          SBPL
        end

        # Wrap a command for confined execution.
        def wrap(cmd, scratch_dir, stores_dir)
          ['sandbox-exec', '-p', profile(scratch_dir, stores_dir), *cmd]
        end

        # Driver-side promotion of verdict-passed results (AGT-1 return path).
        # `manifest` = scratch-relative file paths. Refuses any entry that
        # escapes the scratch area or would land in the stores (merge-store
        # probe branch). Returns the list of absolute destination paths written.
        def merge!(scratch_dir, manifest, project_root)
          scratch = realpath_strict(scratch_dir, 'scratch_dir')
          root = realpath_strict(project_root, 'project_root')
          stores = File.join(root, '.kairos')

          written = []
          manifest.each do |rel|
            raise ConfinementError, "absolute path in manifest: #{rel}" if rel.start_with?('/')

            src = File.expand_path(rel, scratch)
            raise ConfinementError, "manifest entry escapes scratch: #{rel}" unless within?(src, scratch)
            raise ConfinementError, "manifest source missing: #{rel}" unless File.file?(src)

            dest = File.expand_path(rel, root)
            unless within?(dest, root)
              raise ConfinementError, "manifest entry escapes project root: #{rel}"
            end
            if within?(dest, stores)
              raise ConfinementError, "merge refused: #{rel} targets the stores (AGT-1: merge never targets the stores)"
            end

            FileUtils.mkdir_p(File.dirname(dest))
            FileUtils.cp(src, dest)
            written << dest
          end
          written
        end

        # Post-run manifest: every regular file now present in the scratch
        # area, relative paths, minus the curated inputs the boundary copied in.
        def manifest(scratch_dir, exclude: [])
          scratch = realpath_strict(scratch_dir, 'scratch_dir')
          excluded = exclude.map { |p| File.expand_path(p, scratch) }
          Dir.glob(File.join(scratch, '**', '*'), File::FNM_DOTMATCH)
             .select { |p| File.file?(p) }
             .reject { |p| excluded.include?(p) }
             .map { |p| p.delete_prefix("#{scratch}/") }
             .sort
        end
      end
    end
  end
end
