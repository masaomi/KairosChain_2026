# frozen_string_literal: true

require 'yaml'
require 'json'
require 'digest'
require_relative 'canon'

module KairosMcp
  module SkillSets
    module ConfidentialityGuard
      # Pinned policy profile (design v0.3 §4, CG-1/CG-3).
      #
      # The profile is loaded once at activation and pinned by content hash;
      # subsequent edits to the file are invisible to the running regime.
      # A missing profile yields the empty policy: every designation absent,
      # therefore total denial (CG-1 fail-closed, §4 zero-profile case).
      class Policy
        class ActivationError < StandardError; end

        # Detection-machinery version, part of the versioned verdict basis
        # (CG-3). Bump when the detection semantics below change.
        ENGINE_VERSION = 'cg-1/1'

        attr_reader :sha256, :profile_path

        def self.load(profile_path)
          raw = if profile_path && File.file?(profile_path)
                  YAML.safe_load(File.read(profile_path)) || {}
                else
                  {}
                end
          raise ActivationError, 'profile must be a YAML mapping' unless raw.is_a?(Hash)
          new(raw, profile_path: profile_path)
        rescue Psych::Exception => e
          raise ActivationError, "profile unparseable: #{e.message}"
        end

        def initialize(data, profile_path: nil)
          @data = data
          @profile_path = profile_path
          @sha256 = Digest::SHA256.hexdigest(Canon.canonical(data))
          @content_classes = compile_content_classes(data['content_classes'])
          @restricted = normalize_restricted(data['restricted_storage'])
        end

        def empty?
          @data.empty?
        end

        # 'permitted' / 'denied' / nil (absent designation => denial, CG-1)
        def persistent_admission(layer)
          value = @data.dig('persistent_admissions', layer.to_s)
          value.is_a?(String) ? value : nil
        end

        # Returns the matching restricted-storage designation for a path,
        # or nil when the path is not designated (an undesignated read is
        # not a guarded crossing — design v0.3 §1 scope (c)).
        def restricted_entry(path)
          return nil unless path.is_a?(String) && !path.empty?
          resolved = Policy.resolve(path)
          @restricted.find { |entry| under_root?(resolved, entry[:root]) }
        end

        # True when `path` is the root itself or lives beneath it. Uses a
        # separator-normalized prefix so a root of "/" (whose separator
        # tail would be "//") still matches its children.
        def under_root?(path, root)
          return true if path == root
          prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
          path.start_with?(prefix)
        end

        # Path normalization that matches the read tools' File.realpath
        # semantics (impl review R1/R3). Crucially it does NOT lexically
        # collapse ".." via File.expand_path first — that would discard a
        # symlink component and diverge from what the tool actually reads
        # (e.g. "link/../data" where link -> /root/sub must resolve through
        # the filesystem, not lexically to the parent of link). The full
        # path is realpath'd when it exists; otherwise the deepest existing
        # prefix is realpath'd (walking the raw path, ".." included) and the
        # non-existing tail is appended.
        def self.resolve(path)
          candidate = path.to_s
          candidate = File.join(Dir.pwd, candidate) unless candidate.start_with?(File::SEPARATOR)
          return File.realpath(candidate) if File.exist?(candidate)

          tail = []
          current = candidate
          loop do
            parent = File.dirname(current)
            tail.unshift(File.basename(current))
            current = parent
            break if current == File.dirname(current) # reached the fs root
            return File.join(File.realpath(current), *tail) if File.exist?(current)
          end
          # Nothing along the path exists: best-effort lexical form.
          File.expand_path(candidate)
        rescue ArgumentError
          # Malformed path (e.g. NUL byte): re-raise so the caller's
          # resolve_target turns it into an unextractable denial rather
          # than a crash.
          raise
        end

        # First content-class detection hit on the presented content, or nil.
        # Deterministic: classes are evaluated in profile order (CG-3).
        def content_class_hit(content)
          return nil unless content.is_a?(String)
          @content_classes.find { |klass| klass[:regexp].match?(content) }
        end

        private

        def compile_content_classes(classes)
          Array(classes).map do |klass|
            raise ActivationError, 'content_classes entries must be mappings' unless klass.is_a?(Hash)
            id = klass['id'].to_s
            pattern = klass['pattern']
            raise ActivationError, "content class #{id.inspect} missing id or pattern" if id.empty? || !pattern.is_a?(String)
            begin
              { id: id, regexp: Regexp.new(pattern) }
            rescue RegexpError => e
              raise ActivationError, "content class #{id.inspect} has invalid pattern: #{e.message}"
            end
          end
        end

        def normalize_restricted(entries)
          Array(entries).map do |entry|
            raise ActivationError, 'restricted_storage entries must be mappings' unless entry.is_a?(Hash)
            path = entry['path']
            raise ActivationError, 'restricted_storage entry missing path' unless path.is_a?(String) && !path.empty?
            {
              id: (entry['id'] || path).to_s,
              root: Policy.resolve(path),
              reads: entry['reads'].is_a?(String) ? entry['reads'] : nil
            }
          end
        end
      end
    end
  end
end
