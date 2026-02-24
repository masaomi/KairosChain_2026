# Add fields from the unified implementation plan that were missing
# from the original scaffolding.
class AddUnifiedPlanFields < ActiveRecord::Migration[8.1]
  def change
    # Users: locale, ToS version tracking, API usage limits
    change_table :users, bulk: true do |t|
      t.string :locale, default: "ja"
      t.string :tos_version
      t.integer :daily_api_usage, default: 0
      t.date :daily_api_reset_at
    end

    # Echoes: prompt seed and chapter memory for post-crystallization dialogue
    change_table :echoes, bulk: true do |t|
      t.text :prompt_seed
      t.text :chapter_memory
    end

    # Story sessions: protagonist mode support
    add_column :story_sessions, :protagonist_mode, :string, default: "player"

    # Story scenes: decision actor tracking, lore validation, generation metadata
    change_table :story_scenes, bulk: true do |t|
      t.string :decision_actor, default: "player"
      t.string :lore_validation_status, default: "passed"
      t.jsonb :generation_metadata, default: {}
    end
  end
end
