class AddUniqueIndexActiveSessions < ActiveRecord::Migration[8.0]
  def up
    add_index :story_sessions, [:echo_id, :chapter],
              name: "idx_unique_active_session_per_chapter",
              unique: true,
              where: "status IN ('active', 'paused')"
  end

  def down
    remove_index :story_sessions, name: "idx_unique_active_session_per_chapter", if_exists: true
  end
end
