# frozen_string_literal: true

module Kairomone
  # The fixed vocabularies that steer a cycle (design v0.6 Inv 4, M4, M7, M9):
  # learning subjects, habit values, character kinds, stages, branch levels
  # and the six 0.6 professions as templates. They ship as data with the
  # SkillSet; what an individual stores is judged against them when it leaves
  # toward the composer, so a value the vocabulary does not hold then is
  # dropped, never passed.
  module Vocabulary
    DIR = File.join(PACKAGE_ROOT, 'templates')
    HABITS = {
      'sources' => %w[primary official encyclopedic news community mixed],
      'depth' => %w[survey focused deep],
      'reflection' => %w[concise analytical narrative questioning],
      'stance' => %w[practical theoretical critical creative]
    }.freeze
    FOCUS_MAX = 8
    BRANCH_LEVELS = [10, 30, 100, 300, 600].freeze
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

    def kinds = load('characters.json')['kinds'].map { |k| k['kind'] } + ['unknown']
    def characters = load('characters.json')['kinds']

    def templates = load('professions.json')['templates']
    def template(id) = templates.find { |t| t['id'] == id }

    def stage(level)
      STAGES.reverse.find { |s| level >= s['from'] }
    end

    # The level at which a profession of this tier offers its branches.
    def branch_level(tier) = BRANCH_LEVELS[tier]

    # What a cycle's request may carry from a profession: the names of its
    # focus IDs and the habit values the vocabularies hold now. Anything else
    # it stores — free text, unknown IDs, its name and description — is
    # dropped here.
    def request_context(piece)
      focus = Array(piece.is_a?(Hash) ? piece['focus'] : nil).filter_map do |id|
        known = subject_id(id)
        known && { 'id' => known }.merge(subjects[known])
      end.uniq.first(FOCUS_MAX)
      habits = piece.is_a?(Hash) && piece['habits'].is_a?(Hash) ? piece['habits'] : {}
      { 'focus' => focus, 'habits' => HABITS.each_with_object({}) { |(k, values), h| h[k] = habits[k] if values.include?(habits[k]) } }
    end
  end
end
