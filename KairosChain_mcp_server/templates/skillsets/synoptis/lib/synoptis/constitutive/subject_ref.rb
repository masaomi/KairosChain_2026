# frozen_string_literal: true

require 'digest'
require 'yaml'
require 'date'

module Synoptis
  module Constitutive
    # Resolves a stable subject identity to its persisted L2 context file and computes
    # a digest of the ACTUAL persisted bytes (design v0.9, LED-3).
    #
    # The subject-id is the `context://<session_id>/<context_name>` URI itself. It is
    # stable across file rename/relocation because identity is the URI, not the path:
    # the path is derived from the URI at read time. (If the underlying file is later
    # moved, path resolution is a mechanism detail deferred to §11; the id is stable
    # by construction.)
    #
    # The digest binds the entry to the fact that specific bytes existed at a moment —
    # it proves THAT content matched, not WHAT it said (an audit that needs the wording
    # embeds a snapshot; that is a later slice).
    module SubjectRef
      SCHEME = 'context://'
      DIGEST_ALG = 'sha256'

      module_function

      # "context://<session_id>/<context_name>" -> { session_id:, context_name: }
      def parse(uri)
        s = uri.to_s
        raise ArgumentError, "not a context uri: #{uri}" unless s.start_with?(SCHEME)

        rest = s[SCHEME.length..]
        session_id, context_name = rest.to_s.split('/', 2)
        if session_id.nil? || session_id.empty? || context_name.nil? || context_name.empty?
          raise ArgumentError, "malformed context uri: #{uri}"
        end

        { session_id: session_id, context_name: context_name }
      end

      # Layout: context_dir/<session_id>/<context_name>/<context_name>.md
      def resolve_path(uri, context_dir:)
        p = parse(uri)
        File.join(context_dir, p[:session_id], p[:context_name], "#{p[:context_name]}.md")
      end

      def exists?(uri, context_dir:)
        File.exist?(resolve_path(uri, context_dir: context_dir))
      end

      def read_bytes(uri, context_dir:)
        File.binread(resolve_path(uri, context_dir: context_dir))
      end

      # SHA256 of the subject's persisted content bytes. Raises if the file is absent
      # (fail-closed: never attest content that does not exist).
      def digest(uri, context_dir:)
        Digest::SHA256.hexdigest(read_bytes(uri, context_dir: context_dir))
      end

      # A pre-commit snapshot of the subject's persisted state, for surfacing in a
      # proposal or approval. Content-free about meaning: only size + digest.
      def content_state(uri, context_dir:)
        path = resolve_path(uri, context_dir: context_dir)
        if File.exist?(path)
          bytes = File.binread(path)
          { exists: true, bytes: bytes.bytesize,
            digest: Digest::SHA256.hexdigest(bytes), digest_alg: DIGEST_ALG }
        else
          { exists: false, bytes: 0, digest: nil, digest_alg: DIGEST_ALG }
        end
      end

      # Best-effort read of the frontmatter `type:` field (nil if absent/unparseable).
      # Primary path is a real YAML parse; a regex fallback keeps the criterion robust
      # against frontmatter that YAML.safe_load rejects (e.g. an exotic tagged value),
      # since the criterion only ever needs the single `type` scalar.
      def frontmatter_type(uri, context_dir:)
        path = resolve_path(uri, context_dir: context_dir)
        return nil unless File.exist?(path)

        text = File.read(path)
        fm = extract_frontmatter(text)
        if fm.is_a?(Hash)
          val = fm['type'] || fm[:type]
          return val.to_s if val
        end

        block = frontmatter_block(text)
        return nil unless block

        m = block.match(/^type:\s*(.+?)\s*$/)
        m && m[1].gsub(/\A["']|["']\z/, '')
      end

      # The raw text between the opening and closing `---` fences, or nil.
      def frontmatter_block(text)
        return nil unless text.start_with?('---')

        parts = text.split(/^---\s*$/, 3)
        parts.length < 3 ? nil : parts[1]
      end

      def extract_frontmatter(text)
        block = frontmatter_block(text)
        return nil unless block

        # Permit Date/Time so common frontmatter (`date: 2026-07-05`) parses instead
        # of raising Psych::DisallowedClass and losing the whole hash.
        YAML.safe_load(block, permitted_classes: [Date, Time])
      rescue StandardError
        nil
      end
    end
  end
end
