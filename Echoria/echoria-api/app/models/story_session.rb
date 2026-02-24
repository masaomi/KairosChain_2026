class StorySession < ApplicationRecord
  self.table_name = "story_sessions"

  belongs_to :echo
  has_many :story_scenes, foreign_key: :session_id, dependent: :destroy
  belongs_to :current_beacon, class_name: "StoryBeacon", foreign_key: :current_beacon_id, optional: true

  validates :echo_id, presence: true
  validates :chapter, presence: true
  validates :status, presence: true

  enum :status, { active: "active", paused: "paused", completed: "completed" }

  before_create :initialize_affinity

  scope :active_sessions, -> { where(status: :active) }
  scope :by_chapter, ->(chapter) { where(chapter: chapter) }
  scope :recent, -> { order(created_at: :desc) }

  # Echoria 5-axis affinity system
  DEFAULT_AFFINITY = {
    "tiara_trust" => 50,
    "logic_empathy_balance" => 0,
    "name_memory_stability" => 50,
    "authority_resistance" => 0,
    "fragment_count" => 0
  }.freeze

  def initialize_affinity
    self.affinity = DEFAULT_AFFINITY.dup if affinity.blank?
  end

  def add_affinity_delta(delta)
    current = affinity || DEFAULT_AFFINITY.dup
    delta.each do |key, value|
      next unless current.key?(key.to_s)
      current[key.to_s] = clamp_affinity(key.to_s, current[key.to_s] + value.to_i)
    end
    self.affinity = current
  end

  def progress_percentage
    return 0 if scene_count.zero?
    (scene_count / 20.0 * 100).clamp(0, 100).round(2)
  end

  private

  # Enforce axis ranges
  def clamp_affinity(axis, value)
    case axis
    when "tiara_trust", "name_memory_stability"
      value.clamp(0, 100)
    when "logic_empathy_balance", "authority_resistance"
      value.clamp(-50, 50)
    when "fragment_count"
      [value, 0].max
    else
      value
    end
  end
end
