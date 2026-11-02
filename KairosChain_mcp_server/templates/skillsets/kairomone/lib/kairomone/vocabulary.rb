# frozen_string_literal: true

module Kairomone
  # The fixed vocabularies that steer a cycle (design v0.6 Inv 4, M4, M7, M9;
  # 0.9 Inv 4, N2): learning subjects, learning methods, habit values,
  # character kinds, stages, branch levels and the six 0.6 professions as
  # templates. They ship as data with the SkillSet; what an individual stores
  # is judged against them when it leaves toward the composer, so a value the
  # vocabulary does not hold then is dropped, never passed.
  module Vocabulary
    DIR = File.join(PACKAGE_ROOT, 'templates')
    HABITS = {
      'sources' => %w[primary official encyclopedic news community mixed],
      'depth' => %w[survey focused deep],
      'reflection' => %w[concise analytical narrative questioning],
      'stance' => %w[practical theoretical critical creative]
    }.freeze
    # The habits of an individual that has no profession (0.9 N4).
    NO_PROFESSION_HABITS = { 'sources' => 'mixed', 'depth' => 'survey', 'reflection' => 'concise', 'stance' => 'practical' }.freeze
    FOCUS_MAX = 8
    # Internal (0.9 Inv 5): nothing the SkillSet surfaces names a branch level
    # before it is reached.
    BRANCH_LEVELS = [10, 30, 100, 300, 600].freeze
    MILESTONE = 10 # a drawing is due at every multiple of ten (0.9 N5)
    STAGES = [
      { 'id' => 'egg', 'from' => 1, 'en' => 'Egg', 'ja' => '卵' },
      { 'id' => 'hatchling', 'from' => 5, 'en' => 'Hatchling', 'ja' => '幼体' },
      { 'id' => 'young', 'from' => 20, 'en' => 'Young', 'ja' => '若者' },
      { 'id' => 'adult', 'from' => 100, 'en' => 'Adult', 'ja' => '成体' },
      { 'id' => 'legend', 'from' => 500, 'en' => 'Legend', 'ja' => '伝説' }
    ].freeze

    module_function

    def load(name)
      @cache ||= {}
      @cache[name] ||= JSON.parse(File.read(File.join(DIR, name), encoding: 'UTF-8')).freeze
    end

    # { id => { 'en', 'ja' } }, with retired IDs resolved through aliases.
    def subjects
      @subjects ||= load('subjects.json')['subjects'].to_h { |s| [s['id'], s.slice('en', 'ja')] }.freeze
    end

    def subject_id(id)
      aliases = load('subjects.json')['aliases'] || {}
      # A retired ID points at its successor, which may itself be retired.
      8.times { id = aliases.fetch(id, id) if id.is_a?(String) }
      subjects.key?(id) ? id : nil
    end

    # { id, en, ja } of a subject the vocabulary holds now, or nil.
    def subject_name(id)
      known = subject_id(id)
      known && { 'id' => known }.merge(subjects[known])
    end

    # The names of the stored subject IDs the vocabulary holds now, in order,
    # each once; anything else is dropped.
    def subject_names(ids, max: nil)
      names = Array(ids).filter_map { |id| subject_name(id) }.uniq
      max ? names.first(max) : names
    end

    # Learning methods (0.9 N2), resolved like subjects.
    def learning_methods
      @learning_methods ||= load('methods.json')['methods'].to_h { |m| [m['id'], m.slice('en', 'ja')] }.freeze
    end

    def learning_method_id(id)
      aliases = load('methods.json')['aliases'] || {}
      8.times { id = aliases.fetch(id, id) if id.is_a?(String) }
      learning_methods.key?(id) ? id : nil
    end

    def learning_method_names(ids)
      Array(ids).filter_map { |id| (known = learning_method_id(id)) && { 'id' => known }.merge(learning_methods[known]) }.uniq
    end

    # Any shipped kind, 'unknown' (a profile written before a kind was
    # chosen) or 'other' (the kind label says what it is, 0.9 N5).
    def kinds = load('characters.json')['kinds'].map { |k| k['kind'] } + %w[unknown other]
    def characters = load('characters.json')['kinds']

    # The six 0.6 professions: read for a 0.6 selection and as lineage
    # parents; offered to no individual (0.9 Inv 5).
    def templates = load('professions.json')['templates']
    def template(id) = templates.find { |t| t['id'] == id }

    def stage(level)
      STAGES.reverse.find { |s| level >= s['from'] }
    end

    def stage_named(id) = STAGES.find { |s| s['id'] == id }

    # The order of a stage ID (egg 0 … legend 4); an unknown ID ranks below all.
    def stage_rank(id) = STAGES.index { |s| s['id'] == id } || -1

    # The milestone a level answers: the multiple of ten at or below it.
    def milestone(level) = (level.to_i / MILESTONE) * MILESTONE

    # The milestone a drawing recorded before 0.9 answers, from the stage its
    # record holds: the multiple of ten at or below that stage's first level;
    # an unknown stage answers 0 (0.9 N5). Used inside, never shown.
    def stage_milestone(id)
      found = stage_named(id)
      found ? milestone(found['from']) : 0
    end

    # The level at which a profession of this tier offers its branches.
    def branch_level(tier) = BRANCH_LEVELS[tier]

    # What a cycle's request may carry from a profession: the names of its
    # focus IDs and the habit values the vocabularies hold now. Anything else
    # it stores — free text, unknown IDs, its name and description — is
    # dropped here.
    def request_context(piece)
      focus = subject_names(piece.is_a?(Hash) ? piece['focus'] : nil, max: FOCUS_MAX)
      habits = piece.is_a?(Hash) && piece['habits'].is_a?(Hash) ? piece['habits'] : {}
      { 'focus' => focus, 'habits' => HABITS.each_with_object({}) { |(k, values), h| h[k] = habits[k] if values.include?(habits[k]) } }
    end
  end
end
