class CreateAnalyticsEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :analytics_events do |t|
      t.uuid :user_id
      t.uuid :echo_id
      t.string :event_type, null: false
      t.jsonb :event_data, default: {}

      t.timestamps
    end

    add_index :analytics_events, [:event_type, :created_at]
    add_index :analytics_events, :user_id
    add_index :analytics_events, :echo_id
  end
end
