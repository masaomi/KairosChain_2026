# frozen_string_literal: true

require 'yaml'

module Kairomone
  # Text the composer writes (profiles, professions): bounded, without control
  # or format characters, and checked for credentials when it is accepted.
  module ComposedText
    # Key-shaped tokens carry a digit after their prefix's separator, so
    # ordinary hyphenated words ("sky-blue-and-silver-fur") are not caught.
    CREDENTIAL = /(?:\b(?:sk|ghp|github_pat)[-_](?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]{20,}|\bghp_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\bBearer\s+\S{12,}|\b(?:password|api[_ -]?key|access[_ -]?token)\s*[:=]\s*\S+)/i

    module_function

    def field!(value, label, max, allow_empty: false)
      ok = value.is_a?(String) && value.valid_encoding? && value.bytesize <= max && (allow_empty || !value.strip.empty?) &&
           !value.match?(/[[\p{Cc}\p{Cf}\u2028\u2029]&&[^\u200C\u200D]]/) # joiners in emoji sequences are allowed
      raise Error, "#{label} must be text of at most #{max} bytes without control characters" unless ok

      value.strip
    end

    def list!(value, label, max_items, max_each)
      raise Error, "#{label} must be a list of at most #{max_items} items" unless value.is_a?(Array) && value.length <= max_items

      value.map { |v| field!(v, "#{label} item", max_each) }
    end

    # A conservative guard, not a promise of complete secret detection.
    def guard!(texts)
      raise Error, 'Potential credential detected; remove it before accepting' if texts.flatten.compact.any? { |t| t.to_s.match?(CREDENTIAL) }
    end
  end

  # Profile versions (design v0.6 M4): content-addressed files
  # profile/<sha256>.json, schema 2, no identity and no baseline. The current
  # profile is the latest accepted kairomone_profile record whose piece is
  # present; an individual made before 0.8 stands on its schema-1 profile.json
  # until a version is accepted. A version — the name included — takes effect
  # only when the owner accepts it; versions append and earlier ones stay
  # readable.
  module Profile
    FIELDS = %w[name kind kind_label appearance personality voice interests origin created_at].freeze
    ORIGINS = %w[init create proposal legacy import fusion].freeze
    MATERIAL_KINDS = %w[instruction_mode host_l2 free_text checkboxes template legacy none].freeze
    NAME_MAX = 256 # as the 0.6 display name and kairomone_init
    MATERIAL_LIMIT = 24 * 1024
    MODE_FILES = { 'developer' => 'kairos.md', 'user' => 'kairos_quickguide.md', 'tutorial' => 'kairos_tutorial.md' }.freeze

    module_function

    # The version kairomone_init writes: the name the owner gave, nothing composed.
    def initial(name:, origin:)
      { 'schema_version' => 2, 'name' => name, 'kind' => 'unknown', 'kind_label' => '', 'appearance' => '',
        'personality' => [], 'voice' => '', 'interests' => [],
        'origin' => { 'kind' => origin, 'material_sha256' => nil }, 'created_at' => Time.now.utc.iso8601 }
    end

    # A version from what the composer drafted: every field bounded and free
    # of control characters, the kind from the shipped kinds.
    def build(fields, origin:, material_sha256: nil)
      raise Error, 'A profile is an object' unless fields.is_a?(Hash)

      unknown = fields.keys.map(&:to_s) - %w[name kind kind_label appearance personality voice interests]
      raise Error, "Unexpected profile fields: #{unknown.join(', ')}" unless unknown.empty?

      f = fields.transform_keys(&:to_s)
      kind = f.fetch('kind', 'unknown')
      raise Error, "kind must be one of #{Vocabulary.kinds.join(', ')}" unless Vocabulary.kinds.include?(kind)
      raise Error, 'origin must be a known origin' unless ORIGINS.include?(origin)
      raise Error, 'material_sha256 must be a sha256 hex digest' unless material_sha256.nil? || Progression::SHA.match?(material_sha256.to_s)

      { 'schema_version' => 2, 'name' => ComposedText.field!(f['name'], 'name', NAME_MAX), 'kind' => kind,
        'kind_label' => ComposedText.field!(f.fetch('kind_label', ''), 'kind_label', 80, allow_empty: true),
        'appearance' => ComposedText.field!(f.fetch('appearance', ''), 'appearance', 1000, allow_empty: true),
        'personality' => ComposedText.list!(f.fetch('personality', []), 'personality', 8, 80),
        'voice' => ComposedText.field!(f.fetch('voice', ''), 'voice', 300, allow_empty: true),
        'interests' => ComposedText.list!(f.fetch('interests', []), 'interests', 8, 80),
        'origin' => { 'kind' => origin, 'material_sha256' => material_sha256 }, 'created_at' => Time.now.utc.iso8601 }
    end

    # Where the material came from: 'none' carries no hash.
    def material!(kind, sha256)
      raise Error, "material_kind must be one of #{MATERIAL_KINDS.join(', ')}" unless MATERIAL_KINDS.include?(kind)
      raise Error, 'material_sha256 must be a sha256 hex digest' unless sha256.nil? || Progression::SHA.match?(sha256.to_s)
      raise Error, "material_kind none names no material, so it takes no material_sha256" if kind == 'none' && sha256
    end

    # The host's active instruction mode, read only: its name, sha256 and a
    # bounded text the composer may draft a profile from (M9).
    def instruction_mode_material(host_root)
      config_path = Paths.checked(host_root, 'skills/config.yml')
      mode = 'tutorial'
      if File.file?(config_path)
        config = YAML.safe_load(Paths.read(host_root, 'skills/config.yml', limit: 262_144)) rescue nil
        mode = config['instructions_mode'].to_s if config.is_a?(Hash) && config['instructions_mode'].to_s.match?(/\A[a-z][a-z0-9_-]{0,63}\z/)
      end
      file = MODE_FILES.fetch(mode, "#{mode}.md")
      relative = "skills/#{file}"
      return { name: mode, present: false } unless File.file?(Paths.checked(host_root, relative))

      bytes = Paths.read(host_root, relative, limit: 4 * 1024 * 1024)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      return { name: mode, present: true, sha256: Digest::SHA256.hexdigest(bytes), text: nil, note: 'not UTF-8' } unless text.valid_encoding?

      shown = text.byteslice(0, MATERIAL_LIMIT).scrub('')
      { name: mode, present: true, sha256: Digest::SHA256.hexdigest(bytes), text: shown, truncated: shown.bytesize < bytes.bytesize }
    end

    def valid?(value)
      value.is_a?(Hash) && value['schema_version'] == 2 && (value.keys - ['schema_version']).sort == FIELDS.sort &&
        value['name'].is_a?(String) && !value['name'].strip.empty? && value['name'].bytesize <= NAME_MAX
    end

    def texts(piece) = [piece['name'], piece['kind_label'], piece['appearance'], piece['voice'], *piece['personality'], *piece['interests']]
  end

  class Instance
    PROPOSAL_LIMIT = 256 * 1024 # a drawing of 64 KiB, JSON-escaped, fits
    PROPOSALS_SHOWN = 10

    # { sha256:, piece: } of the latest accepted profile version whose file is
    # present and well formed, or nil. A version the ledger accepts but the
    # files lack falls back to the one before it (M15).
    def current_profile_piece(ledger = nil)
      return nil unless @root && File.exist?(Paths.checked(root, 'storage/blockchain.json'))

      ledger ||= chain
      Records.of_type(ledger, 'kairomone_profile').reverse_each do |record|
        found = profile_piece(record['sha256'])
        return found if found
      end
      nil
    end

    # What the composer may draft a profile from (M9): the host's active
    # instruction mode (name, sha256, bounded text, read only), the 0.6 seeds
    # of an individual made before 0.8, and the character starters. Host L2 the
    # composer reads with the host's own tools.
    def profile_material
      ensure_initialized!
      mode = instruction_mode_material
      legacy = legacy_profile
      companion = companion_status[:companion]
      { success: true, kairomone: address, instruction_mode: mode,
        seeds: { name: companion['display_name'] || name, legacy_profile: legacy,
                 personality: companion['personality'], direction: companion['direction'] },
        kinds: Vocabulary.characters, material_kinds: Profile::MATERIAL_KINDS,
        note: 'Draft a profile from this material and show it to the owner in full; it takes effect only when they accept it. ' \
              'The name lives in the profile.' }
    end

    # Whether this Kairomone was created with this identity, profile and first
    # profession (the creation retry check; creation times are not compared).
    def created_with?(wanted_identity, wanted_profile, wanted_profession)
      ledger = chain
      return false unless identity(ledger) == wanted_identity

      made = Records.of_type(ledger, 'kairomone_profile').first
      first = Records.of_type(ledger, 'kairomone_profession').first
      return false unless made && first && made['origin'] == 'create' && first['origin'] == 'create'

      stored = profile_piece(made['sha256'])&.fetch(:piece)
      stored_profession = profession_piece(first['sha256'])
      strip = ->(h) { h&.reject { |k, _| %w[created_at].include?(k) } }
      strip.call(stored) == strip.call(wanted_profile) && stored_profession == wanted_profession
    end

    # Stores what the composer drafted as a proposal; nothing takes effect.
    def propose_profile(fields:, material_kind: 'none', material_sha256: nil)
      Profile.material!(material_kind, material_sha256)
      piece = Profile.build(fields, origin: 'proposal', material_sha256: material_sha256)
      # A draft that carries a credential is refused before it is stored:
      # proposals stay on disk and travel in backups.
      ComposedText.guard!(Profile.texts(piece))
      with_lock do
        ensure_writable!('L2')
        sha = write_piece('proposals', { 'kind' => 'profile', 'piece' => piece, 'material_kind' => material_kind,
                                         'proposed_at' => Time.now.utc.iso8601 })
        { success: true, proposal: sha, piece: piece, kairomone: address,
          note: 'Show the owner this profile in full. It takes effect only when they accept it (kairomone_profile accept).' }
      end
    end

    # Proposals in full, newest first, each with its state: waiting for the
    # owner, accepted or chosen, or superseded (an offer the owner can no
    # longer choose: not the latest from the profession in force).
    def proposals
      ensure_initialized!
      ledger = chain
      accepted = Records.each(ledger).filter_map { |r, _| r['proposal_sha256'] }
      chosen_offers = Records.of_type(ledger, 'kairomone_profession').filter_map { |r| r['offer_sha256'] }
      open_offer = current_offer(ledger, current_profession(ledger)[:id])&.fetch(:sha)
      items = piece_files('proposals').filter_map do |sha|
        doc = read_proposal(sha) or next
        state = if accepted.include?(sha) then 'accepted'
                elsif chosen_offers.include?(sha) then 'chosen'
                elsif doc['kind'] == 'profession_offer' && sha != open_offer then 'superseded'
                else 'waiting'
                end
        item = { 'proposal' => sha, 'state' => state, 'accepted' => %w[accepted chosen].include?(state) }.merge(doc)
        # A drawing leaves only if it passes the art check now (Inv 6).
        if doc['kind'] == 'art'
          begin
            Art.check!(doc['svg'])
          rescue Error => e
            item = item.merge('svg' => nil, 'art_check' => e.message)
          end
        end
        item
      end
      items = items.sort_by { |i| i['proposed_at'] || i['offered_at'] || '' }.reverse
      waiting, done = items.partition { |i| i['state'] == 'waiting' }
      { success: true, kairomone: address, proposals: waiting.first(PROPOSALS_SHOWN) + done.first(PROPOSALS_SHOWN),
        waiting_total: waiting.length, answered_total: done.length,
        note: "The #{PROPOSALS_SHOWN} newest waiting proposals in full, then the #{PROPOSALS_SHOWN} newest answered or superseded ones; " \
              'accepted profile versions are in history.' }
    end

    # The owner accepts a proposed profile. Its text is judged by the rules
    # current now, the piece is written, then its acceptance record is
    # appended. Accepting the same proposal again changes nothing.
    def accept_profile(proposal:)
      sha_of = lambda { |s| Progression::SHA.match?(s.to_s) or raise Error, 'proposal must be a proposal sha256' }
      sha_of.call(proposal)
      with_lock do
        ensure_writable!('L2')
        ledger = chain
        if (prior = Records.of_type(ledger, 'kairomone_profile').find { |r| r['proposal_sha256'] == proposal })
          next { success: true, accepted: true, preserved: true, sha256: prior['sha256'], profile: profile, kairomone: address }
        end
        doc = read_proposal(proposal) or raise Error, 'No such proposal'
        raise Error, 'This proposal is not a profile' unless doc['kind'] == 'profile'

        piece = doc['piece']
        raise Error, 'The proposed profile no longer reads as a profile' unless Profile.valid?(piece)
        Profile.build(piece.slice('name', 'kind', 'kind_label', 'appearance', 'personality', 'voice', 'interests'),
                      origin: 'proposal', material_sha256: piece.dig('origin', 'material_sha256'))
        ComposedText.guard!(Profile.texts(piece))
        sha = write_piece('profile', piece)
        Records.append!(ledger, [{ 'type' => 'kairomone_profile', 'sha256' => sha, 'origin' => 'proposal', 'proposal_sha256' => proposal,
                                   'material_kind' => doc['material_kind'], 'material_sha256' => piece.dig('origin', 'material_sha256') }], -> { chain })
        { success: true, accepted: true, sha256: sha, profile: profile, kairomone: address }
      end
    end

    # Every accepted version, oldest first; earlier ones stay readable.
    def profile_history
      ensure_initialized!
      versions = Records.of_type(chain, 'kairomone_profile').map do |r|
        found = profile_piece(r['sha256'])
        { 'sha256' => r['sha256'], 'origin' => r['origin'], 'present' => !found.nil?, 'piece' => found&.fetch(:piece) }
      end
      { success: true, kairomone: address, legacy_profile: legacy_profile, versions: versions }
    end

    private

    def profile_piece(sha)
      return nil unless Progression::SHA.match?(sha.to_s)

      relative = "profile/#{sha}.json"
      return nil unless File.file?(Paths.checked(root, relative))

      bytes = Paths.read(root, relative, limit: 65_536)
      return nil unless Digest::SHA256.hexdigest(bytes) == sha

      piece = JSON.parse(bytes) rescue nil
      Profile.valid?(piece) ? { sha256: sha, piece: piece } : nil
    end

    def read_proposal(sha)
      return nil unless Progression::SHA.match?(sha.to_s)

      relative = "proposals/#{sha}.json"
      return nil unless File.file?(Paths.checked(root, relative))

      bytes = Paths.read(root, relative, limit: PROPOSAL_LIMIT)
      return nil unless Digest::SHA256.hexdigest(bytes) == sha

      doc = JSON.parse(bytes) rescue nil
      doc.is_a?(Hash) ? doc : nil
    end

    def piece_files(dir)
      path = Paths.checked(root, dir)
      return [] unless File.directory?(path)

      Dir.children(path).sort.filter_map { |n| n.delete_suffix('.json') if n.match?(/\A[0-9a-f]{64}\.json\z/) }
    end

    def instruction_mode_material = Profile.instruction_mode_material(host_root)
  end
end
