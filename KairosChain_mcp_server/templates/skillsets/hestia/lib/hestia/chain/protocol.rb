# frozen_string_literal: true

require_relative 'protocol/types'
require_relative 'protocol/philosophy_declaration'
require_relative 'protocol/observation_log'

module Hestia
  module Chain
    module Protocol
      class << self
        def version
          '0.1.0'
        end

        def valid_philosophy_type?(type)
          Types::PHILOSOPHY_TYPES.include?(type.to_s) || type.to_s.start_with?('custom.')
        end

        def valid_observation_type?(type)
          Types::OBSERVATION_TYPES.include?(type.to_s) || type.to_s.start_with?('custom.')
        end

        def predefined_compatibility_tag?(tag)
          Types::COMPATIBILITY_TAGS.include?(tag.to_s)
        end
      end
    end
  end
end
