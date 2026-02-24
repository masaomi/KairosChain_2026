class EchoMessage < ApplicationRecord
  self.table_name = "echo_messages"

  belongs_to :echo_conversation, foreign_key: :conversation_id

  validates :conversation_id, presence: true
  validates :role, presence: true
  validates :content, presence: true

  enum role: { user: "user", assistant: "assistant" }

  scope :recent, -> { order(created_at: :desc) }
end
