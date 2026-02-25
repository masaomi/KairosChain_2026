class User < ApplicationRecord
  has_secure_password validations: false

  has_many :echoes, dependent: :destroy
  has_many :conversations, class_name: "EchoConversation", through: :echoes

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, presence: true, length: { minimum: 8 }, if: :password_required?
  validates :password_confirmation, presence: true, if: :password_required?
  validates :name, presence: true

  enum :subscription_status, { free: "free", premium: "premium", enterprise: "enterprise" }

  scope :by_provider, ->(provider) { where(provider: provider) }
  scope :by_uid, ->(uid) { where(uid: uid) }

  class << self
    def find_or_create_from_oauth(auth_hash)
      provider = auth_hash["provider"]
      uid = auth_hash["uid"]
      user = by_provider(provider).by_uid(uid).first

      unless user
        user = create!(
          provider: provider,
          uid: uid,
          email: auth_hash["info"]["email"],
          name: auth_hash["info"]["name"],
          avatar_url: auth_hash["info"]["image"],
          password: SecureRandom.hex(16),
          subscription_status: :free,
          tos_accepted_at: Time.current
        )
      end

      user
    end
  end

  private

  def password_required?
    provider.blank?
  end
end
