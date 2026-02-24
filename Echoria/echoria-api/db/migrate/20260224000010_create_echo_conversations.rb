class CreateEchoConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :echo_conversations, id: :uuid do |t|
      t.uuid :echo_id, null: false

      t.timestamps
    end

    add_foreign_key :echo_conversations, :echoes, column: :echo_id
    add_index :echo_conversations, :echo_id
  end
end
