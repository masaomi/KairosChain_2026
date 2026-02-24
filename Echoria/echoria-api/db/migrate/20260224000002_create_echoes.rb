class CreateEchoes < ActiveRecord::Migration[8.1]
  def change
    create_table :echoes, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.string :name, null: false
      t.string :avatar_url
      t.string :status, default: "embryo"
      t.jsonb :personality, default: {}

      t.timestamps
    end

    add_foreign_key :echoes, :users, column: :user_id
    add_index :echoes, :user_id
    add_index :echoes, :status
  end
end
