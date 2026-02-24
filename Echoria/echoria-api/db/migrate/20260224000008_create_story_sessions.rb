class CreateStorySessions < ActiveRecord::Migration[8.1]
  def change
    create_table :story_sessions, id: :uuid do |t|
      t.uuid :echo_id, null: false
      t.string :chapter, null: false
      t.integer :current_beacon_id
      t.integer :scene_count, default: 0
      t.jsonb :affinity, default: {}
      t.string :status, default: "active"

      t.timestamps
    end

    add_foreign_key :story_sessions, :echoes, column: :echo_id
    add_index :story_sessions, :echo_id
    add_index :story_sessions, :status
    add_index :story_sessions, :chapter
  end
end
