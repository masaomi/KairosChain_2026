class EchoConversation < ApplicationRecord
  self.table_name = "echo_conversations"

  belongs_to :echo
  has_many :echo_messages, foreign_key: :conversation_id, dependent: :destroy

  validates :echo_id, presence: true

  scope :recent, -> { order(created_at: :desc) }

  def add_message(role, content)
    echo_messages.create!(role: role, content: content)
  end

  def conversation_history(limit: 50)
    echo_messages.order(created_at: :asc).last(limit).map { |msg| { role: msg.role, content: msg.content } }
  end
end
