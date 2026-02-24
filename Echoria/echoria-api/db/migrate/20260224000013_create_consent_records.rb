class CreateConsentRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :consent_records do |t|
      t.uuid :user_id, null: false
      t.string :document_type, null: false
      t.string :document_version, null: false
      t.datetime :accepted_at, null: false
      t.string :ip_address
      t.string :user_agent

      t.timestamps
    end

    add_foreign_key :consent_records, :users, column: :user_id
    add_index :consent_records, [:user_id, :document_type]
  end
end
