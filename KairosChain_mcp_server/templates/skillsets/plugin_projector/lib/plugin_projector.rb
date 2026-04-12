# frozen_string_literal: true

module KairosMcp
  module SkillSets
    module PluginProjector
      SKILLSET_ROOT = File.expand_path('..', __dir__)
      VERSION = '0.1.0'

      def self.load!
        Dir[File.join(SKILLSET_ROOT, 'tools', '*.rb')].each { |f| require f }
      end

      def self.unload!
        # No persistent state to clean up
      end
    end
  end
end
