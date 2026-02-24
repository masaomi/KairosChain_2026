class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :uuid do |t|
      t.string :email, null: false
      t.string :password_digest
      t.string :provider
      t.string :uid
      t.string :name, null: false
      t.string :avatar_url
      t.datetime :tos_accepted_at
      t.string :subscription_status, default: "free"

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, [:provider, :uid], unique: true
  end
end
