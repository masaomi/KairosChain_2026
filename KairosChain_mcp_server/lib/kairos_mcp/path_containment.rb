# frozen_string_literal: true

module KairosMcp
  # Path guards for store-rooted file access.
  #
  # The L1 (knowledge) and L2 (context) layers address files by joining
  # caller-supplied values onto a store root. Two different shapes of value
  # arrive there, and they need two different guards:
  #
  #   safe_segment?  a knowledge name, a context name, a session id — each is
  #                  exactly one directory below the store root. "." and ".."
  #                  are not names; they collapse back onto the root, which is
  #                  how a delete addressed "inside" the store can take the
  #                  store itself.
  #
  #   contained?     a whole path, including the multi-segment tail of a URI
  #                  (scripts/sub/run.py) or of an HTTP request. Here segments
  #                  are legitimately many, so the guard is where the joined
  #                  path resolves.
  #
  # Invariant: every path the storage layers open, create, move, or delete
  # resolves strictly inside the store root it was addressed against, and every
  # caller-supplied name denotes one directory rather than a route.
  module PathContainment
    module_function

    # True if +segment+ is a single, ordinary path component.
    #
    # Rejects the empty string, "." and ".." (both resolve to a directory the
    # caller did not name), anything containing a separator (which would make
    # the value a route rather than a name), an absolute path, and a NUL byte
    # (which raises out of every File method rather than returning false).
    #
    # @param segment [Object] caller-supplied name / session id
    # @return [Boolean]
    def safe_segment?(segment)
      return false unless segment.is_a?(String)
      return false if segment.empty? || segment == '.' || segment == '..'
      return false if segment.include?(File::SEPARATOR) || segment.include?("\0")
      return false if File::ALT_SEPARATOR && segment.include?(File::ALT_SEPARATOR)

      !segment.start_with?(File::SEPARATOR)
    end

    # True if +path+ resolves to a location at or under the real path of +base+.
    #
    # Resolution walks the literal path, never a lexically pre-collapsed one.
    # That ordering is the whole point: File.expand_path("store/link/../x")
    # yields "store/x" and cancels the symlink, while the kernel traverses
    # `link` first and lands wherever it points. Collapsing before resolving
    # would make this predicate answer about a path nobody opens.
    #
    # A path that does not exist yet (create paths) is resolved as far as it
    # does exist, and the missing tail is appended. A ".." surviving in that
    # tail means the resolution never got to interpret it, so the result is
    # refused rather than collapsed.
    #
    # @param base [String] store root
    # @param path [String] candidate path built by joining onto +base+
    # @return [Boolean]
    def contained?(base, path)
      base_real = File.realpath(base)
      target = resolve_as_far_as_it_exists(path)

      # An unresolved ".." in the tail would let a lexical prefix match succeed
      # on a string the kernel would resolve elsewhere.
      return false if target.split(File::SEPARATOR).include?('..')

      prefix = base_real.end_with?(File::SEPARATOR) ? base_real : base_real + File::SEPARATOR
      target == base_real || target.start_with?(prefix)
    rescue SystemCallError, ArgumentError, TypeError
      # Missing or unreadable base, symlink loop, NUL byte, non-string input:
      # fail closed rather than raise into a caller expecting a boolean.
      false
    end

    # Maximum symlink hops before giving up, mirroring the kernel's own limit.
    # A cycle normally surfaces as Errno::ELOOP from File.realpath; this bounds
    # the one case realpath cannot see, a chain of dangling links.
    MAX_SYMLINK_HOPS = 40

    # realpath of the deepest existing ancestor of +path+, with the tail that
    # does not exist yet appended. The walk shortens the literal path one
    # component at a time, so every symlink that does exist is resolved by the
    # kernel with its true meaning.
    def resolve_as_far_as_it_exists(path)
      dir = path
      tail = []
      hops = 0

      loop do
        begin
          return File.join(File.realpath(dir), *tail.reverse)
        rescue Errno::ENOENT
          # A DANGLING SYMLINK ALSO RAISES ENOENT, and it is not a missing
          # component: the link exists, and a write through it lands on its
          # target. Reading this branch as "not created yet" would answer about
          # the link's own location instead of where the kernel would go, and a
          # link inside the store pointing at a not-yet-existing file outside it
          # would be judged contained.
          if File.symlink?(dir) && (hops += 1) <= MAX_SYMLINK_HOPS
            target = File.readlink(dir)
            # A relative link is relative to the directory holding the link.
            dir = target.start_with?(File::SEPARATOR) ? target : File.join(File.dirname(dir), target)
            next
          end

          parent = File.dirname(dir)
          # Nothing along the path exists; expand lexically so the caller still
          # gets an absolute string. Any ".." left in it is caught above.
          return File.expand_path(path) if parent == dir

          tail << File.basename(dir)
          dir = parent
        end
      end
    end
    private_class_method :resolve_as_far_as_it_exists
  end
end
