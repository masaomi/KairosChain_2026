class Echo < ApplicationRecord
  belongs_to :user
  has_many :story_sessions, dependent: :destroy
  has_many :conversations, foreign_key: :echo_id, dependent: :destroy
  has_many :echo_blocks, dependent: :destroy
  has_many :echo_action_logs, dependent: :destroy
  has_many :echo_knowledge, dependent: :destroy
  has_many :echo_skills, dependent: :destroy

  validates :name, presence: true
  validates :user_id, presence: true

  enum status: { embryo: "embryo", growing: "growing", crystallized: "crystallized" }

  before_create :initialize_personality

  def kairos_chain
    @kairos_chain ||= Echoria::KairosBridge.new(self)
  end

  private

  def initialize_personality
    self.personality = {
      traits: {},
      affinities: {},
      memories: [],
      skills: []
    }
  end
end
