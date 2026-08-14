# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      # Where a mode's hook declaration lives, and how it is read.
      #
      # Two locations, in this order:
      #
      #   1. beside the mode body — <mode>.mode_hooks.json next to <mode>.md
      #   2. inside this SkillSet — mode_hooks/<mode>.json
      #
      # (1) is preferred and is what an instance should use. The declaration
      # carries the mode's own numbers, so it belongs with the mode: an author
      # editing the body sees the declaration in the same directory, and a
      # SkillSet upgrade cannot touch it. (2) exists for declarations that ship
      # with a mode distributed as part of a SkillSet.
      #
      # A leading underscore marks a file in mode_hooks/ that is not a mode —
      # the two schemas and the shipped example. Those never resolve.
      module ModeHooksLocator
        EXTENSIONS = %w[json yml yaml].freeze
        module_function

        # @return [String, nil] path to the declaration, or nil if none exists
        def find(mode, skillset_root:, mode_body_path: nil)
          return nil if mode.to_s.empty? || mode.to_s.start_with?('_')

          candidates(mode, skillset_root, mode_body_path).find { |p| File.exist?(p) }
        end

        def candidates(mode, skillset_root, mode_body_path)
          beside = if mode_body_path
                     dir = File.dirname(mode_body_path)
                     EXTENSIONS.map { |e| File.join(dir, "#{mode}.mode_hooks.#{e}") }
                   else
                     []
                   end
          inside = EXTENSIONS.map { |e| File.join(skillset_root, 'mode_hooks', "#{mode}.#{e}") }
          beside + inside
        end

        def load(path)
          return nil if path.nil?
          return JSON.parse(File.read(path, encoding: 'UTF-8')) if path.end_with?('.json')

          require 'yaml'
          YAML.safe_load(File.read(path, encoding: 'UTF-8'))
        end
      end
    end
  end
end
