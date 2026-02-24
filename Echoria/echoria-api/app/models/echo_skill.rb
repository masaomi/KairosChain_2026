class EchoSkill < ApplicationRecord
  self.table_name = "echo_skills"

  belongs_to :echo

  validates :echo_id, presence: true
  validates :skill_id, presence: true
  validates :title, presence: true
  validates :content, presence: true
  validates :layer, presence: true

  validates :echo_id, :skill_id, uniqueness: true

  scope :by_layer, ->(layer) { where(layer: layer) }
  scope :recent, -> { order(created_at: :desc) }

  VALID_LAYERS = %w[L0 L1 L2 L3].freeze

  validates :layer, inclusion: { in: VALID_LAYERS }
end
