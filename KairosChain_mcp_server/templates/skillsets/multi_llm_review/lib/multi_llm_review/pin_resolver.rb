# frozen_string_literal: true

require 'yaml'
require 'digest'

module KairosMcp
  module SkillSets
    module MultiLlmReview
      # Self-referential SkillSet pin resolver (v0.3 S4 / design §11).
      #
      # Resolves which on-disk copy of a SkillSet to load when the orchestrator
      # wants to run a DIFFERENT version of a SkillSet than the one shipped
      # with the current kairos-chain gem. Used by the multi-LLM review
      # workflow to keep a "reviewer" version of multi_llm_review fixed
      # (e.g., v0.2.3) while reviewing a "reviewee" version (e.g., v0.3.0)
      # under development.
      #
      # Resolution order (first wins):
      #   1. Env var: KAIROS_SKILLSET_PIN_<NAME>=<version>  (session override)
      #   2. Manifest: .kairos/skillsets_pin.yml             (persistent + on-chain)
      #   3. Default:  .kairos/skillsets/<name>/             (normal load)
      #
      # Pinned SkillSets live at .kairos/skillsets_archive/<name>-<version>/.
      # When a pin is active, callers should verify archive integrity by
      # computing sha256_of(archive_dir) and comparing against the
      # blockchain-recorded hash from system_upgrade's snapshot-on-apply hook.
      # That L0 integration (hash verification, chain_record lookup) is
      # tracked as a gem-level follow-up; this module provides the
      # SkillSet-level primitives.
      module PinResolver
        MANIFEST_RELATIVE_PATH = '.kairos/skillsets_pin.yml'
        ARCHIVE_RELATIVE_PATH  = '.kairos/skillsets_archive'
        DEFAULT_RELATIVE_PATH  = '.kairos/skillsets'

        ENV_PREFIX = 'KAIROS_SKILLSET_PIN_'

        module_function

        # Resolve an absolute filesystem path for the named SkillSet, honoring
        # env var > manifest > default. Returns {path:, source:, version:}
        # where source ∈ {:env, :manifest, :default} and version may be nil
        # in the :default case.
        def resolve(skillset_name, project_root: Dir.pwd)
          env_pin = lookup_env_pin(skillset_name)
          if env_pin
            return {
              path: archive_path(project_root, skillset_name, env_pin),
              source: :env, version: env_pin,
              provenance: { set_by: 'env', env_var: env_var_name(skillset_name) }
            }
          end

          manifest_pin = lookup_manifest_pin(project_root, skillset_name)
          if manifest_pin
            version = manifest_pin.is_a?(Hash) ? manifest_pin['version'] : manifest_pin
            return {
              path: archive_path(project_root, skillset_name, version),
              source: :manifest, version: version,
              provenance: manifest_pin.is_a?(Hash) ? manifest_pin : { 'version' => version }
            }
          end

          {
            path: File.join(project_root, DEFAULT_RELATIVE_PATH, skillset_name),
            source: :default, version: nil, provenance: {}
          }
        end

        # Compute a deterministic hash of a SkillSet directory tree: sort file
        # paths, hash each file's (path, content), then SHA256 the
        # concatenation. Post-extraction tampering of any .rb/.yml/.json
        # file changes the result. (v0.3.2 §3 row 4 landing spot.)
        def archive_hash(archive_dir)
          return nil unless Dir.exist?(archive_dir)
          archive_real = File.realpath(archive_dir)
          digest = Digest::SHA256.new
          entries = Dir.glob(File.join(archive_dir, '**', '*'), File::FNM_DOTMATCH).sort
          entries.each do |p|
            next if p.end_with?('/.', '/..')
            lstat = File.lstat(p) rescue nil
            next unless lstat
            rel = p.sub(archive_dir + '/', '')
            digest.update(rel); digest.update("\0")
            if lstat.symlink?
              # Include symlink target AND reject links escaping the archive.
              target = File.readlink(p)
              resolved = File.expand_path(target, File.dirname(p))
              unless resolved.start_with?(archive_real + '/') || resolved == archive_real
                raise ArgumentError,
                  "archive symlink escapes archive_dir: #{rel} → #{target}"
              end
              digest.update('symlink:'); digest.update(target)
            elsif lstat.file?
              digest.update('file:')
              digest.update(format('%04o', lstat.mode & 0o7777))  # permission mode
              digest.update("\0")
              digest.update(File.read(p, mode: 'rb'))
            elsif lstat.directory?
              digest.update('dir:')
            end
            digest.update("\0\n")
          end
          digest.hexdigest
        end

        # Skillset names are restricted to [a-z0-9_] by convention (see
        # existing .kairos/skillsets/ directory). Hyphen support would collide
        # with underscore under upcase-replace, so we reject it explicitly.
        VALID_NAME_RE = /\A[a-z0-9_]+\z/

        def env_var_name(skillset_name)
          unless VALID_NAME_RE.match?(skillset_name)
            raise ArgumentError,
              "skillset name must match #{VALID_NAME_RE.inspect}: #{skillset_name.inspect}"
          end
          "#{ENV_PREFIX}#{skillset_name.upcase}"
        end

        def lookup_env_pin(skillset_name)
          v = ENV[env_var_name(skillset_name)]
          return nil if v.nil? || v.empty?
          v
        end

        def lookup_manifest_pin(project_root, skillset_name)
          path = File.join(project_root, MANIFEST_RELATIVE_PATH)
          return nil unless File.exist?(path)
          begin
            data = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
          rescue StandardError => e
            # Malformed manifest is surfaced so the user knows the pin file
            # is broken and they're getting default-path resolution instead.
            warn "[PinResolver] manifest parse error at #{path}: #{e.class}: #{e.message}"
            return nil
          end
          return nil unless data.is_a?(Hash) && data['pins'].is_a?(Hash)
          data['pins'][skillset_name] || data['pins'][skillset_name.to_sym]
        end

        def archive_path(project_root, skillset_name, version)
          File.join(project_root, ARCHIVE_RELATIVE_PATH, "#{skillset_name}-#{version}")
        end
      end
    end
  end
end
