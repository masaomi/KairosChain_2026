class CreateStoryBeacons < ActiveRecord::Migration[8.1]
  def change
    create_table :story_beacons do |t|
      t.string :chapter, null: false
      t.integer :beacon_order, null: false
      t.string :title, null: false
      t.text :content, null: false
      t.text :tiara_dialogue
      t.jsonb :choices, null: false, default: []
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :story_beacons, [:chapter, :beacon_order], unique: true
    add_index :story_beacons, :chapter
  end
end
