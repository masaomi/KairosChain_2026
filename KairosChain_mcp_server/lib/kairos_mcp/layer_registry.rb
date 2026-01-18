# frozen_string_literal: true

module KairosMcp
  # LayerRegistry: Manages the layered architecture for skills and knowledge
  #
  # Layer hierarchy (legal system analogy):
  #   L0-A (Constitution): skills/kairos.md - Immutable philosophy
  #   L0-B (Law): skills/kairos.rb - Self-modifying meta-rules with full blockchain record
  #   L1 (Ordinance): knowledge/ - Project knowledge with hash-only blockchain record
  #   L2 (Context): context/ - Temporary context without blockchain record
  #
  class LayerRegistry
    LAYERS = {
      L0_constitution: {
        path: 'skills/kairos.md',
        mutable: false,
        blockchain: :none,
        format: :markdown,
        description: 'Kairos philosophy and principles (read-only)'
      },
      L0_law: {
        path: 'skills/kairos.rb',
        mutable: true,
        blockchain: :full,
        format: :ruby_dsl,
        description: 'Kairos meta-rules (self-modifying constraints)'
      },
      L1: {
        path: 'knowledge/',
        mutable: true,
        blockchain: :hash_only,
        format: :anthropic_skill,
        description: 'Project knowledge (Anthropic skills format)'
      },
      L2: {
        path: 'context/',
        mutable: true,
        blockchain: :none,
        format: :anthropic_skill,
        description: 'Temporary context (free modification)'
      }
    }.freeze

    # Kairos meta-skills that can be placed in L0
    KAIROS_META_SKILLS = %i[
      core_safety
      evolution_rules
      layer_awareness
      approval_workflow
      self_inspection
      chain_awareness
    ].freeze

    class << self
      # Get layer configuration for a given path
      def layer_for(path)
        relative_path = normalize_path(path)
        LAYERS.find { |_, config| relative_path.start_with?(config[:path]) }&.first
      end

      # Check if a layer allows modification
      def can_modify?(layer)
        LAYERS[layer]&.[](:mutable) || false
      end

      # Check if a layer requires blockchain recording
      def requires_blockchain?(layer)
        mode = LAYERS[layer]&.[](:blockchain)
        mode && mode != :none
      end

      # Get blockchain recording mode for a layer
      def blockchain_mode(layer)
        LAYERS[layer]&.[](:blockchain) || :none
      end

      # Get the format type for a layer
      def format_for(layer)
        LAYERS[layer]&.[](:format)
      end

      # Get the base path for a layer
      def path_for(layer)
        LAYERS[layer]&.[](:path)
      end

      # Get layer description
      def description_for(layer)
        LAYERS[layer]&.[](:description)
      end

      # Check if a skill ID is a Kairos meta-skill (allowed in L0)
      def kairos_meta_skill?(skill_id)
        KAIROS_META_SKILLS.include?(skill_id.to_sym)
      end

      # Get all layer names
      def all_layers
        LAYERS.keys
      end

      # Get layer summary
      def summary
        LAYERS.map do |layer, config|
          {
            layer: layer,
            path: config[:path],
            mutable: config[:mutable],
            blockchain: config[:blockchain],
            format: config[:format],
            description: config[:description]
          }
        end
      end

      # Validate that a skill belongs to the correct layer
      def validate_skill_layer(skill_id, target_layer)
        case target_layer
        when :L0_law
          unless kairos_meta_skill?(skill_id)
            return {
              valid: false,
              error: "Skill '#{skill_id}' is not a Kairos meta-skill. Only #{KAIROS_META_SKILLS.join(', ')} can be in L0."
            }
          end
        when :L0_constitution
          return { valid: false, error: 'L0 constitution (kairos.md) is immutable.' }
        end

        { valid: true }
      end

      private

      def normalize_path(path)
        # Remove base directory prefix if present
        base_dir = File.expand_path('../../', __dir__)
        path = path.sub(base_dir, '').sub(%r{^/}, '')
        path
      end
    end
  end
end
