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

          # SBPL is last-match-wins: the /dev write-allow admits the ptys and
          # tty/null the subprocess needs (dynamically allocated, so a literal
          # set risks breaking a real run), but a trailing deny re-closes the
          # raw-device danger the blanket allow would otherwise open. The store
          # read-deny is last so it wins over (allow default).
          [scratch, stores].each do |p|
            raise ConfinementError, "path unsafe for SBPL (metacharacter): #{p}" if p.match?(/["\\\n]/)
          end
          <<~SBPL
            (version 1)
            (allow default)
            (deny file-write*)
            (allow file-write* (subpath "#{scratch}"))
            (allow file-write* (subpath "/dev"))
            (deny file-write* (subpath "/dev/disk") (subpath "/dev/rdisk"))
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

            # realpath the source: a string-only expand_path would let an
            # executor-planted symlink inside scratch pass the within? check
            # while File.file?/cp follow it to the stores — a copy-out primitive
            # with driver privileges. Resolve first, then re-check containment.
            src = realpath_strict(File.expand_path(rel, scratch), "manifest source #{rel}")
            unless within?(src, scratch)
              raise ConfinementError, "manifest entry resolves outside scratch (symlink escape): #{rel}"
            end
            unless File.file?(src) && !File.symlink?(File.expand_path(rel, scratch))
              raise ConfinementError, "manifest entry is not a regular file or is a symlink: #{rel}"
            end

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

        # Content digest of a scratch-relative regular file, or nil.
        def digest_of(scratch, rel)
          require 'digest'
          full = File.expand_path(rel, scratch)
          return nil unless within?(full, scratch) && File.file?(full) && !File.symlink?(full)

          Digest::SHA256.file(full).hexdigest
        end

        # Baseline digests of the curated inputs, taken right after they are
        # copied in — so the post-run manifest can exclude an input only if it
        # is UNCHANGED, and include it (a real output) if the act overwrote it.
        def baseline(scratch_dir, rel_paths)
          scratch = realpath_strict(scratch_dir, 'scratch_dir')
          rel_paths.each_with_object({}) { |rel, h| h[rel] = digest_of(scratch, rel) }
        end

        # Post-run manifest: every regular (non-symlink) file now in the scratch
        # area, relative paths, minus inputs whose content is unchanged from the
        # baseline. A symlink is never a produced result — it is skipped so it
        # cannot smuggle an out-of-scratch reference into the merge set.
        def manifest(scratch_dir, baseline: {})
          scratch = realpath_strict(scratch_dir, 'scratch_dir')
          Dir.glob(File.join(scratch, '**', '*'), File::FNM_DOTMATCH)
             .reject { |p| File.symlink?(p) }
             .select { |p| File.file?(p) }
             .map { |p| p.delete_prefix("#{scratch}/") }
             .reject { |rel| baseline.key?(rel) && baseline[rel] && baseline[rel] == digest_of(scratch, rel) }
             .sort
        end
      end
    end
  end
end
