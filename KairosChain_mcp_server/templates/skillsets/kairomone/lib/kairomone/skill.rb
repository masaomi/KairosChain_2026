# frozen_string_literal: true

module Kairomone
  # Skills (design 0.9 Inv 4, Inv 5, N2): content-addressed pieces
  # skills/<sha256>.json, each derived from one own growth entry
  # (Instance#own_growth) and naming it and its hash. A skill holds learning
  # methods (IDs from templates/methods.json) and subject IDs; it changes how
  # an individual learns, never what it may do. It waits as a proposal and is
  # in force only after the owner accepts it; the owner retires it at any
  # time, and a skill's latest record decides, so a retired one can be
  # accepted again. In force: accepted and not retired, its file present and
  # of the right shape, its source still an own growth entry with that hash,
  # and at most eight. Exchange and fusion leave skills out this round.
  module Skill
    FIELDS = %w[name description source methods focus].freeze
    METHODS_MAX = 4
    FOCUS_MAX = 4
    IN_FORCE_MAX = 8

    module_function

    # A piece from what the composer drafted: methods and focus from the
    # shipped vocabularies now; name and description are display text.
    def build(fields)
      raise Error, 'A skill is an object' unless fields.is_a?(Hash)

      f = fields.transform_keys(&:to_s)
      unknown = f.keys - FIELDS
      raise Error, "Unexpected skill fields: #{unknown.join(', ')}" unless unknown.empty?

      source = f['source'].is_a?(Hash) ? f['source'].transform_keys(&:to_s) : nil
      unless source && source.keys.sort == %w[entry_id sha256] && Paths::ID.match?(source['entry_id'].to_s) && Progression::SHA.match?(source['sha256'].to_s)
        raise Error, 'source is {entry_id, sha256}: one own growth entry of this Kairomone and the sha256 it holds now (kairomone_skill material)'
      end

      methods = f['methods']
      raise Error, "methods is a list of 1–#{METHODS_MAX} method IDs (kairomone_skill material)" unless methods.is_a?(Array) && methods.length.between?(1, METHODS_MAX)

      methods = methods.map { |id| Vocabulary.learning_method_id(id) or raise Error, "method #{id.to_s[0, 40].inspect} is not in the method vocabulary" }
      raise Error, 'methods repeat a method' unless methods.uniq.length == methods.length

      focus = f.fetch('focus', [])
      raise Error, "focus is a list of at most #{FOCUS_MAX} subject IDs" unless focus.is_a?(Array) && focus.length <= FOCUS_MAX

      focus = focus.map { |id| Vocabulary.subject_id(id) or raise Error, "focus #{id.to_s[0, 40].inspect} is not in the subject vocabulary" }
      raise Error, 'focus repeats a subject' unless focus.uniq.length == focus.length

      { 'schema_version' => 1, 'name' => ComposedText.field!(f['name'], 'name', 80),
        'description' => ComposedText.field!(f.fetch('description', ''), 'description', 600, allow_empty: true),
        'source' => { 'entry_id' => source['entry_id'], 'sha256' => source['sha256'] }, 'methods' => methods, 'focus' => focus }
    end

    # Shape only: a stored piece is read as it was stored; its values are
    # judged against the vocabularies when they leave.
    def shape?(piece)
      text = ->(v, max) { v.is_a?(String) && v.bytesize <= max && v.valid_encoding? && !v.match?(/[\p{Cc}\p{Cf}]/) }
      list = ->(v, max) { v.is_a?(Array) && v.length <= max && v.all? { |x| x.is_a?(String) && x.bytesize <= 64 } }
      source = piece.is_a?(Hash) ? piece['source'] : nil
      piece.is_a?(Hash) && (piece.keys - ['schema_version']).sort == FIELDS.sort && text.call(piece['name'], 80) &&
        text.call(piece['description'], 600) && list.call(piece['methods'], METHODS_MAX) && list.call(piece['focus'], FOCUS_MAX) &&
        source.is_a?(Hash) && source.keys.sort == %w[entry_id sha256] && Paths::ID.match?(source['entry_id'].to_s) &&
        Progression::SHA.match?(source['sha256'].to_s)
    end

    def texts(piece) = [piece['name'], piece['description']]
  end

  class Instance
    # What the composer drafts a skill from: the method vocabulary and this
    # individual's own growth entries (L1), newest first. Read an entry in
    # full with kairomone_knowledge get.
    def skill_material(limit: 50)
      ensure_initialized!
      ledger = chain
      growth = own_growth(ledger)
      titles = knowledge_entries(ledger).to_h { |e| [e['id'], e['title']] }
      own = growth[:cycles].reverse.map do |c|
        { 'entry_id' => c['l1_id'], 'sha256' => c['l1_sha256'], 'title' => titles[c['l1_id']],
          'subjects' => Vocabulary.subject_names(c['subjects']) }
      end
      { success: true, kairomone: address, methods: Vocabulary.learning_methods.map { |id, names| { 'id' => id }.merge(names) },
        own_growth_entries: own.first(limit), own_growth_total: own.length, in_force: skills_in_force(ledger, growth).length,
        in_force_max: Skill::IN_FORCE_MAX, unknown: growth[:unknown],
        note: 'Draft a skill from one own growth entry: name (at most 80 bytes), description (at most 600), 1–4 methods from this ' \
              'list, up to 4 subject IDs (kairomone_profession subjects), and source {entry_id, sha256} as listed here. Show the ' \
              'owner the draft in full; it takes effect only when they accept it.' }
    end

    # Stores what the composer drafted as a proposal; nothing takes effect.
    def propose_skill(skill:)
      piece = Skill.build(skill)
      ComposedText.guard!(Skill.texts(piece)) # proposals stay on disk and travel in backups
      with_lock do
        ensure_writable!('L2')
        ledger = chain
        source_own!(piece, own_growth(ledger))
        sha = write_piece('proposals', { 'kind' => 'skill', 'piece' => piece, 'proposed_at' => Time.now.utc.iso8601 })
        { success: true, proposal: sha, piece: piece, kairomone: address,
          note: 'Show the owner this skill in full. It takes effect only when they accept it (kairomone_skill accept).' }
      end
    end

    # The owner accepts a proposed skill: judged again by the rules current
    # now, its source still an own growth entry, at most eight accepted and
    # not retired; the piece is written, then kairomone_skill is appended.
    # Accepting it while it is accepted changes nothing.
    def accept_skill(proposal:)
      raise Error, 'proposal must be a proposal sha256' unless Progression::SHA.match?(proposal.to_s)

      with_lock do
        ensure_writable!('L2')
        ledger = chain
        doc = read_proposal(proposal) or raise Error, 'No such proposal'
        raise Error, 'This proposal is not a skill' unless doc['kind'] == 'skill'

        piece = doc['piece']
        raise Error, 'The proposed skill no longer reads as a skill' unless Skill.shape?(piece)

        Skill.build(piece.slice(*Skill::FIELDS)) # the vocabularies as they are now
        ComposedText.guard!(Skill.texts(piece))
        sha = Digest::SHA256.hexdigest(JSON.pretty_generate(piece) + "\n")
        states = skill_states(ledger)
        if states.dig(sha, :accepted)
          next { success: true, accepted: true, preserved: true, sha256: sha, skills: skill_list[:skills], kairomone: address }
        end

        source_own!(piece, own_growth(ledger))
        accepted = states.count { |_sha, s| s[:accepted] }
        raise Error, "At most #{Skill::IN_FORCE_MAX} skills are accepted at once; retire one first (kairomone_skill retire)" if accepted >= Skill::IN_FORCE_MAX

        raise Error, 'The skill could not be stored as proposed' unless write_piece('skills', piece) == sha

        Records.append!(ledger, [{ 'type' => 'kairomone_skill', 'sha256' => sha, 'proposal_sha256' => proposal, 'source' => piece['source'] }], -> { chain })
        { success: true, accepted: true, sha256: sha, skills: skill_list[:skills], kairomone: address }
      end
    end

    # The owner retires a skill at any time; it stays readable and can be
    # accepted again.
    def retire_skill(sha256:)
      raise Error, 'sha256 must be a skill sha256' unless Progression::SHA.match?(sha256.to_s)

      with_lock do
        ensure_writable!('L2')
        ledger = chain
        state = skill_states(ledger)[sha256] or raise Error, 'No skill with this sha256 was accepted here'
        next { success: true, retired: true, preserved: true, sha256: sha256, skills: skill_list[:skills], kairomone: address } unless state[:accepted]

        Records.append!(ledger, [{ 'type' => 'kairomone_skill_retired', 'sha256' => sha256 }], -> { chain })
        { success: true, retired: true, sha256: sha256, skills: skill_list[:skills], kairomone: address }
      end
    end

    # Every skill ever accepted, oldest first, with whether it is in force
    # and why not; and the skill proposals that wait.
    def skill_list
      ensure_initialized!
      ledger = chain
      growth = own_growth(ledger)
      in_force = skills_in_force(ledger, growth).map { |s| s[:sha256] }
      skills = skill_states(ledger).map do |sha, state|
        piece = skill_piece(sha)
        reason = if !state[:accepted] then 'retired'
                 elsif piece.nil? then 'its file is absent or does not read as a skill'
                 elsif !own_growth_cycle(piece['source']['entry_id'], piece['source']['sha256'], growth) then 'its source is no longer an own growth entry with that hash'
                 elsif !in_force.include?(sha) then "more than #{Skill::IN_FORCE_MAX} are accepted"
                 end
        skill_view(sha, piece).merge('state' => reason ? (state[:accepted] ? 'out_of_force' : 'retired') : 'in_force', 'reason' => reason)
      end
      answered = Set.new(Records.each(ledger).filter_map { |r, _| r['proposal_sha256'] })
      waiting = piece_files('proposals').filter_map do |sha|
        next if answered.include?(sha)

        doc = read_proposal(sha)
        next unless doc && doc['kind'] == 'skill' && Skill.shape?(doc['piece'])

        skill_view(nil, doc['piece']).merge('proposal' => sha, 'proposed_at' => doc['proposed_at'])
      end
      { success: true, kairomone: address, skills: skills, in_force: in_force.length, in_force_max: Skill::IN_FORCE_MAX,
        waiting: waiting.sort_by { |w| w['proposed_at'].to_s }.reverse, unknown: growth[:unknown] }
    end

    # [{ sha256:, piece: }] of the skills in force, in the order of their
    # acceptance, at most IN_FORCE_MAX (the latest accepted).
    def skills_in_force(ledger = chain, growth = own_growth(ledger))
      skill_states(ledger).filter_map do |sha, state|
        next unless state[:accepted]

        piece = skill_piece(sha) or next
        next unless own_growth_cycle(piece['source']['entry_id'], piece['source']['sha256'], growth)

        { sha256: sha, piece: piece, at: state[:at] }
      end.sort_by { |s| s[:at] }.last(Skill::IN_FORCE_MAX)
    end

    private

    # { sha => { accepted: true|false, at: position of its latest record } },
    # in order of first acceptance: a skill's latest record decides.
    def skill_states(ledger)
      states = {}
      Records.each(ledger).each_with_index do |(record, _block), position|
        next unless %w[kairomone_skill kairomone_skill_retired].include?(record['type']) && Progression::SHA.match?(record['sha256'].to_s)
        next if record['type'] == 'kairomone_skill_retired' && !states.key?(record['sha256'])

        states[record['sha256']] = { accepted: record['type'] == 'kairomone_skill', at: position }
      end
      states
    end

    def skill_piece(sha)
      return nil unless Progression::SHA.match?(sha.to_s)

      relative = "skills/#{sha}.json"
      return nil unless File.file?(Paths.checked(root, relative))

      bytes = Paths.read(root, relative, limit: 65_536)
      return nil unless Digest::SHA256.hexdigest(bytes) == sha

      piece = JSON.parse(bytes) rescue nil
      Skill.shape?(piece) ? piece : nil
    end

    def skill_view(sha, piece)
      return { 'sha256' => sha, 'present' => false } unless piece

      { 'sha256' => sha, 'present' => true, 'name' => piece['name'], 'description' => piece['description'],
        'methods' => Vocabulary.learning_method_names(piece['methods']), 'focus' => Vocabulary.subject_names(piece['focus']),
        'source' => piece['source'] }.compact
    end

    def source_own!(piece, growth)
      return if own_growth_cycle(piece['source']['entry_id'], piece['source']['sha256'], growth)

      raise Error, "The source #{piece['source']['entry_id']} is not an own growth entry of this Kairomone holding that sha256 (kairomone_skill material)"
    end
  end
end
