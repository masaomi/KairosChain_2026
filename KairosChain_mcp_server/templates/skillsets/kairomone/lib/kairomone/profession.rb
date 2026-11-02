# frozen_string_literal: true

module Kairomone
  # Professions (design 0.8 v0.6 M4, M7; 0.9 Inv 5, N4): content-addressed
  # pieces professions/<sha256>.json. A profession changes what and how a
  # Kairomone learns — its focus subjects and habits reach the composer at
  # every cycle, in closed form — never what it may do. Branch levels are
  # internal: nothing surfaced names one before it is reached. When the level
  # is at or past the next branch level the composer generates exactly three
  # professions from the individual's own profile, material, lineage and
  # growth; the owner picks one or asks for three new ones; offers come one at
  # a time, in order, for as long as the level is at or past the next branch
  # level. Every chosen profession records its parents. No fixed list is
  # offered: an individual that has chosen none has none, and no template
  # becomes its parent; a 0.6 selection still reads as its template, and a
  # template stays readable as a lineage parent.
  module Profession
    FIELDS = %w[name description focus habits parents tier origin].freeze
    ORIGINS = %w[create branch template import fusion].freeze
    TIER_MAX = Vocabulary::BRANCH_LEVELS.length
    PARENT = /\A([0-9a-f]{64}|template:[a-z][a-z0-9_]{0,40})\z/

    module_function

    # A piece from what the composer drafted. Focus and habits must come from
    # the shipped vocabularies now; name and description are display text.
    def build(fields, parents:, tier:, origin:)
      raise Error, 'A profession is an object' unless fields.is_a?(Hash)

      f = fields.transform_keys(&:to_s)
      unknown = f.keys - %w[name description focus habits]
      raise Error, "Unexpected profession fields: #{unknown.join(', ')}" unless unknown.empty?

      focus = f.fetch('focus', [])
      raise Error, "focus is a list of at most #{Vocabulary::FOCUS_MAX} subject IDs" unless focus.is_a?(Array) && focus.length <= Vocabulary::FOCUS_MAX

      resolved = focus.map { |id| Vocabulary.subject_id(id) or raise Error, "focus #{id.to_s[0, 40].inspect} is not in the subject vocabulary (kairomone_profession subjects)" }
      raise Error, 'focus repeats a subject' unless resolved.uniq.length == resolved.length

      habits = f['habits']
      raise Error, "habits takes exactly #{Vocabulary::HABITS.keys.join(', ')}" unless habits.is_a?(Hash) && habits.keys.map(&:to_s).sort == Vocabulary::HABITS.keys.sort

      habits = habits.transform_keys(&:to_s)
      Vocabulary::HABITS.each do |k, values|
        raise Error, "habits.#{k} must be one of #{values.join(', ')}" unless values.include?(habits[k])
      end
      raise Error, 'origin must be a known origin' unless ORIGINS.include?(origin)
      raise Error, 'tier out of range' unless tier.is_a?(Integer) && tier.between?(0, TIER_MAX)
      raise Error, 'parents must name professions' unless parents.is_a?(Array) && parents.all? { |p| PARENT.match?(p.to_s) }

      { 'schema_version' => 1, 'name' => ComposedText.field!(f['name'], 'name', 80),
        'description' => ComposedText.field!(f.fetch('description', ''), 'description', 600, allow_empty: true),
        'focus' => resolved, 'habits' => Vocabulary::HABITS.keys.to_h { |k| [k, habits[k]] },
        'parents' => parents, 'tier' => tier, 'origin' => origin }
    end

    def from_template(template)
      { 'schema_version' => 1, 'name' => template['name'], 'description' => template['description'], 'focus' => template['focus'].dup,
        'habits' => template['habits'].dup, 'parents' => [], 'tier' => 0, 'origin' => 'template' }
    end

    # Shape only: a stored piece is read as it was stored; its values are
    # judged against the vocabularies when they leave (Vocabulary.request_context).
    def shape?(piece)
      text = ->(v, max) { v.is_a?(String) && v.bytesize <= max && v.valid_encoding? && !v.match?(/[\p{Cc}\p{Cf}]/) }
      piece.is_a?(Hash) && (piece.keys - ['schema_version']).sort == FIELDS.sort && text.call(piece['name'], 80) &&
        text.call(piece['description'], 600) && piece['focus'].is_a?(Array) && piece['focus'].all? { |f| f.is_a?(String) } &&
        piece['habits'].is_a?(Hash) && piece['habits'].values.all? { |v| v.is_a?(String) } &&
        piece['parents'].is_a?(Array) && piece['parents'].all? { |p| PARENT.match?(p.to_s) && p.is_a?(String) } &&
        piece['tier'].is_a?(Integer) && piece['tier'].between?(0, TIER_MAX)
    end

    def texts(piece) = [piece['name'], piece['description']]

    SELECTION_GONE = 'Kairomone 0.9 offers no fixed list of professions: a Kairomone has none until it chooses one from the three its ' \
                     'branch offer composes from its own profile and growth (kairomone_profession status, offer, choose). The six 0.6 ' \
                     'templates stay only so that a 0.6 selection and a lineage parent still read as they did.'
  end

  class Instance
    # The profession in force: the latest accepted piece that is present;
    # without one, a 0.6 selection read as its template (when unlocked, as
    # 0.6 did); without that, none (nil).
    # => { id:, piece:, template: (id or nil), record: (or nil) } or nil
    def current_profession(ledger = nil, level: nil)
      ledger ||= chain
      Records.of_type(ledger, 'kairomone_profession').reverse_each do |record|
        piece = profession_piece(record['sha256'])
        return { id: record['sha256'], piece: piece, template: nil, record: record } if piece
      end
      selected = profession_selection['selected_id']
      template = selected && Vocabulary.template(selected)
      return nil unless template

      level ||= progression_status(ledger)[:level]
      return nil unless level >= template['unlock_level']

      { id: "template:#{template['id']}", piece: Profession.from_template(template), template: template['id'], record: nil }
    end

    # tier: the branches taken (0 with no profession), never a level. Whether
    # a branch is due is shown; the level it opens at is not (0.9 Inv 5).
    def profession_status(progression: nil)
      ensure_initialized!
      ledger = chain
      level = (progression || progression_status(ledger))[:level]
      current = current_profession(ledger, level: level)
      piece = current && current[:piece]
      selection = profession_selection
      context = Vocabulary.request_context(piece || { 'focus' => [], 'habits' => Vocabulary::NO_PROFESSION_HABITS })
      tier = piece ? piece['tier'] : 0
      opens = Vocabulary.branch_level(tier)
      offer = current_offer(ledger, current && current[:id])
      { selected_id: selection['selected_id'], effective_id: current && (current[:template] || current[:id]), name: piece && piece['name'],
        learning_bias: { topics: context['focus'].map { |f| f['en'] }, max_topic_fraction: 0.5 },
        current: current && { id: current[:id], name: piece['name'], description: piece['description'], focus: context['focus'],
                              habits: context['habits'], tier: piece['tier'], parents: piece['parents'], origin: piece['origin'] },
        tier: tier, lineage: piece ? profession_lineage(piece) : [],
        branch: { due: !opens.nil? && level >= opens && offer.nil?,
                  offer: offer && { offer: offer[:sha], candidates: offer[:doc]['candidates'] } },
        note: 'A profession changes what and how this Kairomone learns, never what it may do: no tool, permission, limit, run or L0 changes with it.' +
              (current ? '' : ' This Kairomone has no profession yet; it chooses one from its first branch offer.') }
    end

    # The composer offers exactly three professions generated from this
    # individual's own profile and material, lineage and growth
    # (profession_material), while the level is at or past the next branch
    # level. Nothing takes effect until the owner chooses; asking for three
    # new ones is another offer. An individual with no profession offers
    # candidates whose parents are [].
    def offer_professions(candidates:)
      with_lock do
        ensure_writable!('L2')
        ledger = chain
        level = progression_status(ledger)[:level]
        current = current_profession(ledger, level: level)
        tier = current ? current[:piece]['tier'] : 0
        opens = Vocabulary.branch_level(tier)
        raise Error, 'No branch is open for this profession' if opens.nil? || level < opens
        raise Error, 'An offer holds exactly three professions' unless candidates.is_a?(Array) && candidates.length == 3

        parents = current ? [current[:id]] : []
        pieces = candidates.map { |c| Profession.build(c, parents: parents, tier: tier + 1, origin: 'branch') }
        ComposedText.guard!(pieces.flat_map { |p| Profession.texts(p) }) # offers stay on disk and travel in backups
        raise Error, 'The three professions need three different names' unless pieces.map { |p| p['name'] }.uniq.length == pieces.length

        from = current && current[:id]
        doc = { 'kind' => 'profession_offer', 'from' => from, 'tier' => tier + 1, 'level' => level,
                'candidates' => pieces, 'offered_at' => Time.now.utc.iso8601 }
        sha = write_piece('proposals', doc)
        Records.append!(ledger, [{ 'type' => 'kairomone_offer', 'sha256' => sha, 'from' => from, 'tier' => tier + 1 }], -> { chain })
        { success: true, offer: sha, candidates: pieces, kairomone: address,
          note: 'Show the owner all three. One takes effect only when they choose it; they may ask for three new ones instead.' }
      end
    end

    # What the composer generates a branch's three professions from (0.9 N4):
    # the profile in force, the creation material's kind and hash (and the
    # host's instruction-mode text only while its sha256 is still that hash;
    # 0.8 stores no material text), the profession and individual lineage,
    # the learned subjects, the skills in force and the titles of the newest
    # own growth entries. L1 comes only from own growth entries (0.9 Inv 10).
    def profession_material(titles: 20)
      ensure_initialized!
      ledger = chain
      growth = own_growth(ledger)
      made = Records.of_type(ledger, 'kairomone_profile').first
      kind = made ? (made['material_kind'] || 'none') : (legacy_profile ? 'legacy' : 'none')
      material_sha = made && Progression::SHA.match?(made['material_sha256'].to_s) ? made['material_sha256'] : nil
      text = nil
      text_note = if kind == 'instruction_mode' && material_sha
                    mode = instruction_mode_material
                    if mode[:present] && mode[:sha256] == material_sha && mode[:text]
                      text = mode[:text]
                      "The host's instruction mode #{mode[:name]} is still the text this Kairomone was made from"
                    else
                      'The instruction-mode text this Kairomone was made from is no longer available'
                    end
                  else
                    'Kairomone stores no material text, only its kind and hash'
                  end
      names = knowledge_entries(ledger).to_h { |e| [e['id'], e['title']] }
      status = profession_status
      current = status[:current]
      { success: true, kairomone: address, profile: profile,
        material: { kind: kind, sha256: material_sha, text: text, note: text_note },
        profession: current && current.slice(:name, :description, :focus, :habits, :tier),
        profession_lineage: status[:lineage].map { |l| l[:name] },
        lineage: Records.of_type(ledger, 'kairomone_lineage').map { |r| { kind: r['kind'].to_s, sources: Array(r['sources']).filter_map { |src| src['name'] if src.is_a?(Hash) } } },
        learned_subjects: learned_subjects(growth),
        skills: skills_in_force(ledger, growth).map { |s| skill_view(nil, s[:piece]).except('source', 'present') },
        own_growth_titles: growth[:cycles].reverse.first(titles).map { |c| names[c['l1_id']] }.compact,
        branch_due: status[:branch][:due],
        note: 'Generate exactly three professions from this material — name, description, up to eight focus subject IDs and one ' \
              'value for each habit — and offer them (kairomone_profession offer). Never tell the owner when a branch comes.' }
    end

    # The owner chooses one of the latest offer's three professions.
    def choose_profession(offer:, index:)
      raise Error, 'offer must be an offer sha256' unless Progression::SHA.match?(offer.to_s)
      raise Error, 'index is 0, 1 or 2' unless [0, 1, 2].include?(index)

      with_lock do
        ensure_writable!('L2')
        ledger = chain
        if (prior = Records.of_type(ledger, 'kairomone_profession').find { |r| r['offer_sha256'] == offer })
          raise Error, 'This offer was already answered with another profession' unless prior['index'] == index

          next { success: true, chosen: true, preserved: true, sha256: prior['sha256'], profession: profession_status, kairomone: address }
        end
        current = current_profession(ledger)
        latest = current_offer(ledger, current && current[:id])
        raise Error, 'This is not the latest offer for the current profession' unless latest && latest[:sha] == offer

        piece = latest[:doc]['candidates'][index]
        raise Error, 'The offered profession no longer reads as a profession' unless Profession.shape?(piece)
        Profession.build(piece.slice('name', 'description', 'focus', 'habits'), parents: piece['parents'], tier: piece['tier'], origin: 'branch')
        ComposedText.guard!(Profession.texts(piece))
        sha = write_piece('professions', piece)
        Records.append!(ledger, [{ 'type' => 'kairomone_profession', 'sha256' => sha, 'origin' => 'branch', 'offer_sha256' => offer,
                                   'index' => index, 'parents' => piece['parents'] }], -> { chain })
        { success: true, chosen: true, sha256: sha, profession: profession_status, kairomone: address }
      end
    end

    # The owner accepts a profession received by exchange (it waits as a
    # proposal, Inv 8). Accepting the same proposal again changes nothing.
    def accept_profession(proposal:)
      raise Error, 'proposal must be a proposal sha256' unless Progression::SHA.match?(proposal.to_s)

      with_lock do
        ensure_writable!('L2')
        ledger = chain
        if (prior = Records.of_type(ledger, 'kairomone_profession').find { |r| r['proposal_sha256'] == proposal })
          next { success: true, accepted: true, preserved: true, sha256: prior['sha256'], profession: profession_status, kairomone: address }
        end
        doc = read_proposal(proposal) or raise Error, 'No such proposal'
        raise Error, 'This proposal is not a received profession (branch offers are answered with choose)' unless doc['kind'] == 'profession'

        piece = doc['piece']
        raise Error, 'The proposed profession no longer reads as a profession' unless Profession.shape?(piece)
        Profession.build(piece.slice('name', 'description', 'focus', 'habits'), parents: piece['parents'], tier: piece['tier'], origin: piece['origin'])
        ComposedText.guard!(Profession.texts(piece))
        # A received piece keeps the bytes (and sha256) it was sent with, so
        # its lineage reads the same here; the acceptance says it came in.
        if doc['received_sha256'] && doc['received_sha256'] != Digest::SHA256.hexdigest(JSON.pretty_generate(piece) + "\n")
          raise Error, 'The received profession does not match the sha256 it was sent with'
        end
        sha = write_piece('professions', piece)
        Records.append!(ledger, [{ 'type' => 'kairomone_profession', 'sha256' => sha, 'origin' => doc['received_sha256'] ? 'import' : piece['origin'],
                                   'proposal_sha256' => proposal, 'parents' => piece['parents'] }], -> { chain })
        { success: true, accepted: true, sha256: sha, profession: profession_status, kairomone: address }
      end
    end

    # A 0.6 template selection is no longer made (0.9 N4); one already made
    # still reads as its template.
    def select_profession(id: nil)
      raise Error, Profession::SELECTION_GONE
    end

    def validate_profession!(value)
      valid = value.is_a?(Hash) && value.keys.sort == %w[schema_version selected_at selected_id] &&
        value['schema_version'] == 1 && !Vocabulary.template(value['selected_id']).nil?
      raise Error, 'Invalid profession selection' unless valid
      Time.iso8601(value.fetch('selected_at'))
      true
    rescue ArgumentError, TypeError
      raise Error, 'Invalid profession selection timestamp'
    end

    private

    def profession_selection
      path = Paths.checked(root, 'profession.json')
      return { 'selected_id' => nil } unless File.exist?(path)
      value = JSON.parse(Paths.read(root, 'profession.json', limit: 4096))
      validate_profession!(value)
      value
    rescue JSON::ParserError => e
      raise Error, "Invalid profession selection: #{e.message}"
    end

    def profession_piece(sha)
      return nil unless Progression::SHA.match?(sha.to_s)

      relative = "professions/#{sha}.json"
      return nil unless File.file?(Paths.checked(root, relative))

      bytes = Paths.read(root, relative, limit: 65_536)
      return nil unless Digest::SHA256.hexdigest(bytes) == sha

      piece = JSON.parse(bytes) rescue nil
      Profession.shape?(piece) ? piece : nil
    end

    # The latest offer made from this profession (nil: from none) and not yet
    # answered.
    def current_offer(ledger, from)
      answered = Records.of_type(ledger, 'kairomone_profession').filter_map { |r| r['offer_sha256'] }
      record = Records.of_type(ledger, 'kairomone_offer').reverse.find { |r| r['from'] == from }
      return nil unless record && !answered.include?(record['sha256'])

      doc = read_proposal(record['sha256'])
      doc && doc['kind'] == 'profession_offer' && doc['candidates'].is_a?(Array) && doc['candidates'].length == 3 ? { sha: record['sha256'], doc: doc } : nil
    end

    # Every ancestor back to templates or first professions, nearest first;
    # a fused profession has two parents and both lines are followed.
    def profession_lineage(piece)
      out = []
      seen = {}
      queue = Array(piece['parents']).dup
      while (parent = queue.shift) && out.length < 32
        next if seen[parent]

        seen[parent] = true
        if parent.start_with?('template:')
          t = Vocabulary.template(parent.delete_prefix('template:'))
          out << { id: parent, name: t ? t['name'] : parent }
          next
        end
        found = profession_piece(parent)
        out << { id: parent, name: found ? found['name'] : '(absent)' }
        queue.concat(Array(found['parents'])) if found
      end
      out
    end

    # The professions these IDs name and every ancestor of theirs present
    # here, nearest first: [[sha, piece]], at most `limit`. What travels with
    # a profession so that its lineage reads the same where it arrives.
    def profession_ancestry(ids, limit:)
      out = []
      seen = {}
      queue = Array(ids).dup
      while (id = queue.shift) && out.length < limit
        next if seen[id] || id.start_with?('template:')

        seen[id] = true
        piece = profession_piece(id) or next
        out << [id, piece]
        queue.concat(Array(piece['parents']))
      end
      out
    end
  end
end
