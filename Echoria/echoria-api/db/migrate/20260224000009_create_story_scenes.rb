class CreateStoryScenes < ActiveRecord::Migration[8.1]
  def change
    create_table :story_scenes do |t|
      t.uuid :session_id, null: false
      t.integer :scene_order, null: false
      t.string :scene_type, null: false
      t.integer :beacon_id
      t.text :narrative, null: false
      t.text :echo_action
      t.text :user_choice
      t.jsonb :affinity_delta, default: {}

      t.timestamps
    end

    add_foreign_key :story_scenes, :story_sessions, column: :session_id
    add_index :story_scenes, :session_id
    add_index :story_scenes, :scene_type
  end
end
