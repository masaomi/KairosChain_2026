class AnalyticsEvent < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :echo, optional: true

  validates :event_type, presence: true

  scope :by_type, ->(type) { where(event_type: type) }
  scope :recent, ->(days: 7) { where("created_at > ?", days.days.ago) }

  def self.track(event_type, user: nil, echo: nil, data: {})
    create!(
      event_type: event_type,
      user_id: user&.id,
      echo_id: echo&.id,
      event_data: data
    )
  end
end
