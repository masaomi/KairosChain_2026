class AddUniqueIndexActiveSessions < ActiveRecord::Migration[8.0]
  def change
    add_index :story_sessions, [:echo_id, :chapter],
              name: "idx_unique_active_session_per_chapter",
              unique: true,
              where: "status IN ('active', 'paused')"
  end
end
