class EchoActionLog < ApplicationRecord
  self.table_name = "echo_action_logs"

  belongs_to :echo

  validates :echo_id, presence: true
  validates :timestamp, presence: true
  validates :action, presence: true

  scope :ordered, -> { order(:timestamp) }
  scope :by_skill, ->(skill_id) { where(skill_id: skill_id) }
  scope :by_layer, ->(layer) { where(layer: layer) }
  scope :recent, ->(days = 7) { where("timestamp > ?", days.days.ago) }
end
