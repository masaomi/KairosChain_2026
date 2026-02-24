class ConsentRecord < ApplicationRecord
  belongs_to :user

  validates :document_type, presence: true, inclusion: { in: %w[tos privacy] }
  validates :document_version, presence: true
  validates :accepted_at, presence: true

  scope :latest_for, ->(user_id, document_type) {
    where(user_id: user_id, document_type: document_type).order(accepted_at: :desc).limit(1)
  }
end
