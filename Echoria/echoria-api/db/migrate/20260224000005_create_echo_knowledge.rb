class CreateEchoKnowledge < ActiveRecord::Migration[8.1]
  def change
    create_table :echo_knowledge do |t|
      t.uuid :echo_id, null: false
      t.string :name, null: false
      t.text :content
      t.string :content_hash
      t.integer :version, default: 1
      t.text :description
      t.jsonb :tags, default: []
      t.boolean :is_archived, default: false

      t.timestamps
    end

    add_foreign_key :echo_knowledge, :echoes, column: :echo_id
    add_index :echo_knowledge, :echo_id
    add_index :echo_knowledge, [:echo_id, :name], unique: true
    add_index :echo_knowledge, :is_archived
  end
end
