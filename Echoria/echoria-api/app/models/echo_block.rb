class EchoBlock < ApplicationRecord
  self.table_name = "echo_blocks"

  belongs_to :echo

  validates :echo_id, presence: true
  validates :block_index, presence: true
  validates :timestamp, presence: true
  validates :data, presence: true
  validates :hash, presence: true

  validates :echo_id, :block_index, uniqueness: { scope: [:echo_id] }

  scope :ordered, -> { order(:block_index) }

  def self.genesis_block(echo_id, timestamp = Time.current)
    create!(
      echo_id: echo_id,
      block_index: 0,
      timestamp: timestamp,
      previous_hash: "0",
      data: { type: "genesis", echo_id: echo_id },
      merkle_root: Digest::SHA256.hexdigest("genesis"),
      hash: Digest::SHA256.hexdigest("genesis-#{timestamp}")
    )
  end
end
