class CreateEchoSkills < ActiveRecord::Migration[8.1]
  def change
    create_table :echo_skills do |t|
      t.uuid :echo_id, null: false
      t.string :skill_id, null: false
      t.string :title, null: false
      t.text :content
      t.string :layer, null: false

      t.timestamps
    end

    add_foreign_key :echo_skills, :echoes, column: :echo_id
    add_index :echo_skills, :echo_id
    add_index :echo_skills, [:echo_id, :skill_id], unique: true
    add_index :echo_skills, :layer
  end
end
