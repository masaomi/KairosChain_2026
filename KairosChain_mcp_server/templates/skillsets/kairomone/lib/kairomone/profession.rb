# frozen_string_literal: true

module Kairomone
  # Professions (design v0.6 Inv 5, M4, M7): content-addressed pieces
  # professions/<sha256>.json. A profession changes what and how a Kairomone
  # learns — its focus subjects and habits reach the composer at every cycle,
  # in closed form — never what it may do. At each branch level the composer
  # offers exactly three professions derived from the current one; the owner
  # picks one or asks for three new ones; every chosen profession records its
  # parents, so each Kairomone carries a profession lineage. The six 0.6
  # professions remain as templates, and a 0.6 selection reads as its template.
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
      { 'schema_version' => 1, 'name' => template['name'], 'description' => template['description'], 'focus' => template['focus'],
        'habits' => template['habits'], 'parents' => [], 'tier' => 0, 'origin' => 'template' }
    end

    # Shape only: a stored piece is read as it was stored; its values are
    # judged against the vocabularies when they leave (Vocabulary.request_context).
    def shape?(piece)
      piece.is_a?(Hash) && (piece.keys - ['schema_version']).sort == FIELDS.sort && piece['name'].is_a?(String) &&
        piece['focus'].is_a?(Array) && piece['habits'].is_a?(Hash) && piece['parents'].is_a?(Array) && piece['tier'].is_a?(Integer)
    end

    def texts(piece) = [piece['name'], piece['description']]
  end

  class Instance
    # The profession in force: the latest accepted piece that is present;
    # without one, the 0.6 selection read as its template (when unlocked, as
    # 0.6 did), or the generalist template.
    # => { id:, piece:, template: (id or nil), record: (or nil) }
    def current_profession(ledger = nil, level: nil)
      ledger ||= chain
      Records.of_type(ledger, 'kairomone_profession').reverse_each do |record|
        piece = profession_piece(record['sha256'])
        return { id: record['sha256'], piece: piece, template: nil, record: record } if piece
      end
      selected = profession_selection['selected_id']
      template = selected && Vocabulary.template(selected)
      level ||= progression_status(ledger)[:level]
      template = Vocabulary.template('generalist') unless template && level >= template['unlock_level']
      { id: "template:#{template['id']}", piece: Profession.from_template(template), template: template['id'], record: nil }
    end

    def profession_status(progression: nil)
      ensure_initialized!
      ledger = chain
      level = (progression || progression_status(ledger))[:level]
      current = current_profession(ledger, level: level)
      piece = current[:piece]
      selection = profession_selection
      catalog = Vocabulary.templates.map do |t|
        { id: t['id'], name: t['name'], unlock_level: t['unlock_level'], unlocked: level >= t['unlock_level'],
          topics: Vocabulary.request_context(t)['focus'].map { |f| f['en'] } }
      end
      context = Vocabulary.request_context(piece)
      next_level = Vocabulary.branch_level(piece['tier'])
      offer = current_offer(ledger, current[:id])
      { selected_id: selection['selected_id'], effective_id: current[:template] || current[:id], name: piece['name'],
        selection_required: selection['selected_id'].nil? && current[:record].nil?,
        selected_unlocked: !!(selection['selected_id'] && catalog.find { |c| c[:id] == selection['selected_id'] }&.fetch(:unlocked)),
        catalog: catalog, learning_bias: { topics: context['focus'].map { |f| f['en'] }, max_topic_fraction: 0.5 },
        current: { id: current[:id], name: piece['name'], description: piece['description'], focus: context['focus'],
                   habits: context['habits'], tier: piece['tier'], parents: piece['parents'], origin: piece['origin'] },
        lineage: profession_lineage(piece),
        branch: { next_level: next_level, due: !next_level.nil? && level >= next_level && offer.nil?,
                  offer: offer && { offer: offer[:sha], candidates: offer[:doc]['candidates'] } },
        note: 'A profession changes what and how this Kairomone learns, never what it may do: no tool, permission, limit, run or L0 changes with it.' }
    end

    # The composer offers exactly three professions derived from the current
    # one, once the branch level is reached. Nothing takes effect until the
    # owner chooses; asking for three new ones is another offer.
    def offer_professions(candidates:)
      with_lock do
        ensure_writable!('L2')
        ledger = chain
        level = progression_status(ledger)[:level]
        current = current_profession(ledger, level: level)
        tier = current[:piece]['tier']
        next_level = Vocabulary.branch_level(tier) or raise Error, 'This profession has no further branch'
        raise Error, "The next branch opens at level #{next_level}; this Kairomone is level #{level}" if level < next_level
        raise Error, 'An offer holds exactly three professions' unless candidates.is_a?(Array) && candidates.length == 3

        pieces = candidates.map { |c| Profession.build(c, parents: [current[:id]], tier: tier + 1, origin: 'branch') }
        raise Error, 'The three professions need three different names' unless pieces.map { |p| p['name'] }.uniq.length == pieces.length

        doc = { 'kind' => 'profession_offer', 'from' => current[:id], 'tier' => tier + 1, 'level' => level,
                'candidates' => pieces, 'offered_at' => Time.now.utc.iso8601 }
        sha = write_piece('proposals', doc)
        Records.append!(ledger, [{ 'type' => 'kairomone_offer', 'sha256' => sha, 'from' => current[:id], 'tier' => tier + 1 }], -> { chain })
        { success: true, offer: sha, candidates: pieces, kairomone: address,
          note: 'Show the owner all three. One takes effect only when they choose it; they may ask for three new ones instead.' }
      end
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

          next { success: true, preserved: true, sha256: prior['sha256'], kairomone: address }
        end
        current = current_profession(ledger)
        latest = current_offer(ledger, current[:id])
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

    # A 0.6 template selection (kept: a 0.6 selection reads as its template).
    def select_profession(id:)
      template = Vocabulary.template(id) or raise Error, 'Unknown profession ID'
      with_lock do
        ensure_initialized!
        raise Error, 'Restored targets are read-only' if @restored
        raise Error, 'This Kairomone has an accepted profession; a new one comes from its branch offers' if Records.of_type(chain, 'kairomone_profession').any?
        level = progression_status[:level]
        raise Error, "Profession unlocks at level #{template['unlock_level']}" unless level >= template['unlock_level']
        previous = profession_selection
        preserved = previous['selected_id'] == id
        unless preserved
          value = { 'schema_version' => 1, 'selected_id' => id, 'selected_at' => Time.now.utc.iso8601 }
          Paths.write(root, 'profession.json', JSON.pretty_generate(value) + "\n", replace: true)
        end
        { success: true, preserved: preserved, profession: profession_status, kairomone: address }
      end
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

    # The latest offer made from this profession and not yet answered.
    def current_offer(ledger, from)
      answered = Records.of_type(ledger, 'kairomone_profession').filter_map { |r| r['offer_sha256'] }
      record = Records.of_type(ledger, 'kairomone_offer').reverse.find { |r| r['from'] == from }
      return nil unless record && !answered.include?(record['sha256'])

      doc = read_proposal(record['sha256'])
      doc && doc['kind'] == 'profession_offer' && doc['candidates'].is_a?(Array) && doc['candidates'].length == 3 ? { sha: record['sha256'], doc: doc } : nil
    end

    # The chain of parents back to a template or a first profession.
    def profession_lineage(piece)
      chain_of = []
      seen = {}
      parents = Array(piece['parents'])
      while (parent = parents.first) && chain_of.length < 16 && !seen[parent]
        seen[parent] = true
        if parent.start_with?('template:')
          t = Vocabulary.template(parent.delete_prefix('template:'))
          chain_of << { id: parent, name: t ? t['name'] : parent }
          break
        end
        found = profession_piece(parent)
        chain_of << { id: parent, name: found ? found['name'] : '(absent)' }
        parents = found ? Array(found['parents']) : []
      end
      chain_of
    end
  end
end
