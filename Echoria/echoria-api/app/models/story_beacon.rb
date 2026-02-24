class StoryBeacon < ApplicationRecord
  self.table_name = "story_beacons"

  validates :chapter, presence: true
  validates :beacon_order, presence: true
  validates :title, presence: true
  validates :content, presence: true
  validates :choices, presence: true

  validates :chapter, :beacon_order, uniqueness: { scope: [:chapter] }

  scope :in_chapter, ->(chapter) { where(chapter: chapter) }
  scope :ordered, -> { order(:beacon_order) }

  def to_narrative
    {
      id: id,
      chapter: chapter,
      order: beacon_order,
      title: title,
      content: content,
      tiara_dialogue: tiara_dialogue,
      choices: choices,
      metadata: metadata
    }
  end
end
