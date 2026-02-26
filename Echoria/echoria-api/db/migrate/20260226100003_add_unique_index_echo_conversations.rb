class AddUniqueIndexEchoConversations < ActiveRecord::Migration[8.0]
  def up
    # Remove the non-unique index added by 20260226000001 (superseded by unique)
    remove_index :echo_conversations, name: "index_echo_conversations_on_echo_id_and_partner", if_exists: true

    add_index :echo_conversations, [:echo_id, :partner],
              name: "idx_unique_echo_conversation_partner",
              unique: true
  end

  def down
    remove_index :echo_conversations, name: "idx_unique_echo_conversation_partner", if_exists: true

    # Restore the non-unique index from 20260226000001
    add_index :echo_conversations, [:echo_id, :partner],
              name: "index_echo_conversations_on_echo_id_and_partner"
  end
end
