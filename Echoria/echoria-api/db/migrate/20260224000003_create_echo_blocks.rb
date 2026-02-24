class CreateEchoBlocks < ActiveRecord::Migration[8.1]
  def change
    create_table :echo_blocks do |t|
      t.uuid :echo_id, null: false
      t.integer :block_index, null: false
      t.datetime :timestamp, null: false
      t.jsonb :data, null: false, default: {}
      t.string :previous_hash
      t.string :merkle_root
      t.string :hash, null: false

      t.timestamps
    end

    add_foreign_key :echo_blocks, :echoes, column: :echo_id
    add_index :echo_blocks, :echo_id
    add_index :echo_blocks, [:echo_id, :block_index], unique: true
  end
end
