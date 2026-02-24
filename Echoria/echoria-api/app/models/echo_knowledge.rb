class EchoKnowledge < ApplicationRecord
  self.table_name = "echo_knowledge"

  belongs_to :echo

  validates :echo_id, presence: true
  validates :name, presence: true
  validates :content, presence: true
  validates :content_hash, presence: true

  validates :echo_id, :name, uniqueness: true

  scope :active, -> { where(is_archived: false) }
  scope :archived, -> { where(is_archived: true) }
  scope :by_tag, ->(tag) { where("tags @> ?", "[\"#{tag}\"]") }
  scope :recent, -> { order(created_at: :desc) }

  before_create :generate_content_hash

  def archive!
    update(is_archived: true)
  end

  def unarchive!
    update(is_archived: false)
  end

  private

  def generate_content_hash
    self.content_hash = Digest::SHA256.hexdigest(content)
  end
end
