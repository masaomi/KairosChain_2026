# frozen_string_literal: true

module Kairomone
  # Raised when a call names no Kairomone and the host lists more than one.
  class AmbiguousError < Error
    attr_reader :listing

    def initialize(listing)
      @listing = listing
      super("#{listing.length} Kairomones live on this host; name one with kairomone: " + listing.map { |l| l[:listing_id] }.join(', '))
    end
  end

  # The host side of "many individuals" (design v0.6 Inv 1, M1, M2). A host
  # lists the individual made before 0.8 in its legacy slot (<data_dir>/kairomone,
  # listed under its identity) and every directory under <data_dir>/kairomones/.
  # An individual enters the host only whole: it is assembled under
  # kairomones/.staging/ while the registry lock is held and becomes listed by
  # one rename. Lock order: registry, then individuals in listing-ID order, and
  # within one individual the growth lock before the instance lock; the policy
  # lock is a leaf; the registry is never taken while an individual lock is
  # held. 0.8 never creates the legacy slot.
  class Host
    LEGACY = 'kairomone'
    REGISTRY = 'kairomones'
    STAGING = 'kairomones/.staging'
    REGISTRY_LOCK = 'kairomones/.registry.lock'

    attr_reader :host_root

    def initialize(host_root: KairosMcp.data_dir)
      expanded = File.expand_path(host_root)
      @host_root = File.exist?(expanded) ? File.realpath(expanded) : expanded
    end

    # [{ listing_id:, root:, legacy: }], sorted by listing ID. Directories that
    # are not individuals (no recognisable identity) are not listed.
    def listing
      found = []
      legacy_root = Paths.checked(host_root, LEGACY)
      if File.file?(Paths.checked(host_root, "#{LEGACY}/profile.json"))
        identity = Instance.legacy_identity(legacy_root)
        found << { listing_id: identity, root: legacy_root, legacy: true } if identity
      end
      registry = Paths.checked(host_root, REGISTRY)
      if File.directory?(registry) && !File.symlink?(registry)
        Dir.children(registry).sort.each do |name|
          next unless Paths::ID.match?(name)

          root = Paths.checked(host_root, "#{REGISTRY}/#{name}")
          next unless File.directory?(root) && !File.symlink?(root)

          found << { listing_id: name, root: root, legacy: false }
        end
      end
      ids = found.map { |l| l[:listing_id] }
      raise Error, "Two individuals are listed as #{(ids.select { |i| ids.count(i) > 1 }).uniq.join(', ')}; inspect #{host_root}" unless ids.uniq.length == ids.length

      found.sort_by { |l| l[:listing_id] }
    end

    def listed?(listing_id) = listing.any? { |l| l[:listing_id] == listing_id }

    # The root of the named individual, or of the only one when none is named.
    # Returns nil when the host lists none and none is named.
    def root_for(listing_id = nil)
      all = listing
      if listing_id
        Paths.id!(listing_id)
        found = all.find { |l| l[:listing_id] == listing_id } or raise Error, "No Kairomone is listed as #{listing_id} on this host"
        return found[:root]
      end
      return nil if all.empty?
      raise AmbiguousError, all.map { |l| l.slice(:listing_id, :legacy) } if all.length > 1

      all.first[:root]
    end

    # Summary of every listed individual, for reads that name none.
    def summaries
      listing.map do |l|
        store = Instance.new(host_root: host_root, root: l[:root])
        base = { listing_id: l[:listing_id], legacy_slot: l[:legacy] }
        begin
          base.merge(identity: store.identity, name: store.name)
        rescue StandardError => e
          base.merge(error: e.message)
        end
      end
    end

    # kairomone_init: the one-individual shorthand. It makes this host's first
    # individual through the registry, preserves an individual already listed
    # under that ID with that identity, and refuses when other individuals live
    # here (several are made with kairomone_create).
    def init(dot_id:, display_name:)
      Paths.id!(dot_id)
      with_registry_lock do
        all = listing
        if (same = all.find { |l| l[:listing_id] == dot_id })
          store = Instance.new(host_root: host_root, root: same[:root])
          raise Error, "#{dot_id} is listed for another identity (#{store.identity}); choose another ID" unless store.identity == dot_id

          next { success: true, initialized: false, preserved: true, root: same[:root], profile: store.profile }
        end
        unless all.empty?
          raise Error, "kairomone_init makes this host's one Kairomone, and #{all.length} already live here " \
                       "(#{all.map { |l| l[:listing_id] }.join(', ')}); make another with kairomone_create"
        end
        root = assemble(dot_id) do |staged|
          staged.open_new!(identity: dot_id, origin: 'create', listing_id: dot_id, name: display_name)
        end
        store = Instance.new(host_root: host_root, root: root)
        { success: true, initialized: true, preserved: false, root: root, profile: store.profile }
      end
    end

    # Assembles an individual under kairomones/.staging/<random>/ and lists it
    # as kairomones/<listing_id>/ by one rename. Must be called with the
    # registry lock held. The block receives the staged Instance (and, when no
    # listing ID is given, returns the one to use); anything it raises leaves
    # nothing listed and no ID used.
    def assemble(listing_id = nil)
      raise Error, 'Assembly needs the registry lock' unless @registry_locked
      if listing_id
        Paths.id!(listing_id)
        raise Error, "#{listing_id} is already listed on this host; choose another listing ID" if listed?(listing_id)
      end

      Paths.mkdir(host_root, STAGING)
      stage = Paths.checked(host_root, "#{STAGING}/s#{SecureRandom.hex(12)}")
      Dir.mkdir(stage, 0o700)
      begin
        staged = Instance.new(host_root: host_root, root: stage)
        chosen = yield staged
        listing_id ||= chosen
        Paths.id!(listing_id)
        target = Paths.checked(host_root, "#{REGISTRY}/#{listing_id}")
        raise Error, "#{listing_id} is already listed on this host; nothing was listed" if File.exist?(target) || File.symlink?(target) || listed?(listing_id)

        File.rename(stage, target)
        target
      ensure
        FileUtils.remove_entry_secure(stage) if File.directory?(stage) && !File.symlink?(stage)
      end
    end

    # Holds the registry lock. Staging directories left by an interrupted
    # assembly are removed under the same lock, so cleanup never meets a live
    # assembly. Re-entrant within one Host object.
    def with_registry_lock
      return yield if @registry_locked

      FileUtils.mkdir_p(host_root, mode: 0o700)
      Paths.mkdir(host_root, REGISTRY)
      lock = Paths.checked(host_root, REGISTRY_LOCK)
      Paths.regular_file!(lock, optional: true, limit: 1024)
      File.open(lock, File::RDWR | File::CREAT, 0o600) do |io|
        io.flock(File::LOCK_EX)
        @registry_locked = true
        begin
          remove_stale_staging!
          yield
        ensure
          @registry_locked = false
        end
      end
    end

    private

    def remove_stale_staging!
      staging = Paths.checked(host_root, STAGING)
      return unless File.directory?(staging) && !File.symlink?(staging)

      Dir.children(staging).each do |name|
        path = File.join(staging, name)
        FileUtils.remove_entry_secure(path) if File.directory?(path) && !File.symlink?(path)
      end
    end
  end
end
