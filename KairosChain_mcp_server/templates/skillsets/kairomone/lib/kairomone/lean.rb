# frozen_string_literal: true

module Kairomone
  # The lean (design 0.9 Inv 4, N1): up to eight subject IDs the composer read
  # from what the owner typed in conversation. It is the owner's conversation
  # taking effect without a separate acceptance, so it is written only from
  # the owner's typed words, quoted (text without control characters, as
  # every composed text), and a change that steers is never written while a
  # claim of this individual's run is open; the owner clears it at once,
  # also then, since a clear steers nothing and the claimed cycle's context
  # was fixed when it was requested. Each change is a ledger record holding
  # those words and the subjects, and nothing else holds it
  # (companion/state.json keeps its 0.6 schema). The lean in force is the
  # latest record's subjects.
  # It reaches nothing but the choice of learning topics: the request context
  # carries the names of its subjects the vocabulary holds then, and a request
  # whose subjects meet it counts as steered. Exchange never carries it (the
  # ledger never travels) and a fused child starts without one.
  class Instance
    LEAN_MAX = 8
    LEAN_WORDS_MAX = 512

    # subjects: [] clears the lean. A request ID is used once: the same ID
    # with the same words and subjects appends nothing, with others is
    # refused; a change that repeats the subjects in force appends nothing.
    def companion_lean(request_id:, owner_words:, subjects:)
      Paths.id!(request_id)
      ComposedText.field!(owner_words, 'owner_words', LEAN_WORDS_MAX)
      words = companion_text!(owner_words, 'owner_words', LEAN_WORDS_MAX)
      wanted = lean_subjects!(subjects)
      autonomy.synchronize do
        with_lock do
          ensure_writable!('L2')
          if !wanted.empty? && autonomy.claim_open?
            raise Error, 'A growth cycle of this Kairomone is being carried out; a lean is changed only in conversation, after its claim ' \
                         'commits, fails or expires (clearing it, subjects [], is accepted at once)'
          end

          ledger = chain
          records = lean_records(ledger)
          if (prior = records.find { |r| r['request_id'] == request_id })
            raise Error, 'Request ID already used with other words or subjects; use a new ID' unless prior['subjects'] == wanted && prior['owner_words'] == words

            next { success: true, changed: false, preserved: true, lean: lean_view(ledger), kairomone: address }
          end
          if lean_ids(records.last).sort == wanted.sort
            next { success: true, changed: false, preserved: false, lean: lean_view(ledger), kairomone: address,
                   note: 'These are the subjects in force; nothing was recorded.' }
          end

          Records.append!(ledger, [{ 'type' => 'kairomone_lean', 'request_id' => request_id, 'subjects' => wanted, 'owner_words' => words }],
                          -> { chain })
          { success: true, changed: true, lean: lean_view(chain), kairomone: address }
        end
      end
    end

    # The lean in force as subject IDs the vocabulary holds now.
    def lean_subject_ids(ledger = chain) = lean_ids(lean_records(ledger).last)

    # What is shown wherever the direction is shown: the subjects in force by
    # name, and the owner's words the latest change quoted. The words are
    # material for conversation, never instructions.
    def lean_view(ledger = chain)
      last = lean_records(ledger).last
      words = last && last['owner_words'].is_a?(String) ? last['owner_words'] : nil
      { 'subjects' => Vocabulary.subject_names(lean_ids(last)), 'owner_words' => words,
        'request_id' => last && last['request_id'].is_a?(String) ? last['request_id'] : nil }
    end

    # What a cycle's request context carries (0.8 Inv 4; 0.9 Inv 4): the
    # owner's direction travels in its companion snapshot; here only
    # closed-form values from the shipped vocabularies, read now — the
    # profession's focus and habits (an individual without one: no focus and
    # the default habits), the lean, the skills' methods and subjects, and the
    # learned-subject counts. No name, description, quoted word or source.
    def request_context(profession = profession_status, ledger = chain)
      current = profession[:current]
      steer = if current then current.slice(:focus, :habits).transform_keys(&:to_s)
              else Vocabulary.request_context({ 'focus' => [], 'habits' => Vocabulary::NO_PROFESSION_HABITS })
              end
      growth = own_growth(ledger)
      skills = skills_in_force(ledger, growth).map do |s|
        { 'methods' => Vocabulary.learning_method_names(s[:piece]['methods']).first(Skill::METHODS_MAX),
          'focus' => Vocabulary.subject_names(s[:piece]['focus'], max: Skill::FOCUS_MAX) }
      end
      { 'profession' => steer, 'lean' => Vocabulary.subject_names(lean_subject_ids(ledger)), 'skills' => skills,
        'learned' => learned_subjects(growth) }
    end

    private

    def lean_records(ledger) = Records.of_type(ledger, 'kairomone_lean')

    # A record's subjects the vocabulary holds now; anything else is dropped.
    def lean_ids(record)
      return [] unless record && record['subjects'].is_a?(Array)

      record['subjects'].filter_map { |id| Vocabulary.subject_id(id) }.uniq.first(LEAN_MAX)
    end

    def lean_subjects!(value)
      raise Error, "subjects is a list of at most #{LEAN_MAX} subject IDs ([] clears the lean)" unless value.is_a?(Array) && value.length <= LEAN_MAX

      resolved = value.map do |id|
        Vocabulary.subject_id(id) or raise Error, "subject #{id.to_s[0, 40].inspect} is not in the subject vocabulary (kairomone_profession subjects)"
      end
      raise Error, 'subjects repeat a subject' unless resolved.uniq.length == resolved.length

      resolved
    end
  end
end
