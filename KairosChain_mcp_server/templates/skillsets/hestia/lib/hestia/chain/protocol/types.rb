# frozen_string_literal: true

module Hestia
  module Chain
    module Protocol
      module Types
        PROTOCOL_ANCHOR_TYPES = %w[
          philosophy_declaration
          observation_log
        ].freeze

        PHILOSOPHY_TYPES = %w[
          exchange
          interaction
          fadeout
        ].freeze

        OBSERVATION_TYPES = %w[
          initiated
          completed
          faded
          observed
        ].freeze

        COMPATIBILITY_TAGS = %w[
          cooperative
          competitive
          observational
          experimental
          conservative
          adaptive
        ].freeze
      end
    end
  end
end
