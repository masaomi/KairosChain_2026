class AddPartnerNameToEchoes < ActiveRecord::Migration[8.0]
  def change
    add_column :echoes, :partner_name, :string, default: "ティアラ"
  end
end
