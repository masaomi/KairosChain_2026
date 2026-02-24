class StoryScene < ApplicationRecord
  self.table_name = "story_scenes"

  belongs_to :story_session, foreign_key: :session_id
  belongs_to :beacon, class_name: "StoryBeacon", foreign_key: :beacon_id, optional: true

  validates :session_id, presence: true
  validates :scene_order, presence: true
  validates :scene_type, presence: true
  validates :narrative, presence: true

  enum :scene_type, { beacon: "beacon", generated: "generated", fallback: "fallback" }
  enum :decision_actor, { player: "player", echo: "echo", system: "system" }, prefix: :decided_by

  scope :ordered, -> { order(:scene_order) }
  scope :by_type, ->(type) { where(scene_type: type) }

  def to_narrative
    {
      id: id,
      order: scene_order,
      type: scene_type,
      narrative: narrative,
      echo_action: echo_action,
      user_choice: user_choice,
      decision_actor: decision_actor,
      affinity_impact: affinity_delta
    }
  end
end
