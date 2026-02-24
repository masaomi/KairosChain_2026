class CreateEchoMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :echo_messages do |t|
      t.uuid :conversation_id, null: false
      t.string :role, null: false
      t.text :content, null: false

      t.timestamps
    end

    add_foreign_key :echo_messages, :echo_conversations, column: :conversation_id
    add_index :echo_messages, :conversation_id
    add_index :echo_messages, :role
  end
end
