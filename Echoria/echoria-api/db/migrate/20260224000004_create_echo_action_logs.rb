class CreateEchoActionLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :echo_action_logs do |t|
      t.uuid :echo_id, null: false
      t.datetime :timestamp, null: false
      t.string :action, null: false
      t.string :skill_id
      t.string :layer
      t.jsonb :details, default: {}

      t.timestamps
    end

    add_foreign_key :echo_action_logs, :echoes, column: :echo_id
    add_index :echo_action_logs, :echo_id
    add_index :echo_action_logs, :timestamp
    add_index :echo_action_logs, :action
  end
end
