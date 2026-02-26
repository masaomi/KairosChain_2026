class AddUniqueIndexEchoConversations < ActiveRecord::Migration[8.0]
  def change
    add_index :echo_conversations, [:echo_id, :partner],
              name: "idx_unique_echo_conversation_partner",
              unique: true
  end
end
