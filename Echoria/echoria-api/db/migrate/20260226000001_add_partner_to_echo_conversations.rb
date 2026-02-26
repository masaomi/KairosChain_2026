class AddPartnerToEchoConversations < ActiveRecord::Migration[8.0]
  def change
    add_column :echo_conversations, :partner, :string, null: false, default: "echo"
    add_index :echo_conversations, [:echo_id, :partner], name: "index_echo_conversations_on_echo_id_and_partner"
  end
end
