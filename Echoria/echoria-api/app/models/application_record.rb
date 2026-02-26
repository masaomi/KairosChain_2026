class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  before_create :generate_uuid, if: :uuid_primary_key?

  private

  def generate_uuid
    self.id = SecureRandom.uuid if id.blank?
  end

  def uuid_primary_key?
    self.class.columns_hash[self.class.primary_key]&.sql_type == "uuid"
  end
end
