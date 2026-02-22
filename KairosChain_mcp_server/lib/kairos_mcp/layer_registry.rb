# frozen_string_literal: true

require_relative '../kairos_mcp'

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
    # NOTE: This is a fallback. The canonical source is the l0_governance skill.
    # See: kairos.md SPEC-010 (Pure Agent Skill Specification)
    KAIROS_META_SKILLS_FALLBACK = %i[
      core_safety
      l0_governance
      evolution_rules
      layer_awareness
      approval_workflow
      self_inspection
      chain_awareness
      audit_rules
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
      # Supports both internal layer keys and SkillSet layer symbols
      def requires_blockchain?(layer)
        mode = blockchain_mode(layer)
        mode && mode != :none
      end

      # Get blockchain recording mode for a layer
      # Supports both internal layer keys (L0_constitution, L0_law) and
      # SkillSet layer symbols (:L0, :L1, :L2)
      def blockchain_mode(layer)
        layer = normalize_layer(layer)
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

      # Get allowed L0 skills from l0_governance skill (or fallback)
      # Implements Pure Agent Skill principle: L0 rules are in L0
      def kairos_meta_skills
        # Try to get from l0_governance skill first (canonical source)
        if defined?(Kairos) && Kairos.respond_to?(:skill)
          governance_skill = Kairos.skill(:l0_governance)
          if governance_skill&.behavior
            begin
              config = governance_skill.behavior.call
              return config[:allowed_skills] if config[:allowed_skills]
            rescue StandardError
              # Fall through to fallback
            end
          end
        end
        
        # Fallback for bootstrapping
        KAIROS_META_SKILLS_FALLBACK
      end

      # Check if a skill ID is a Kairos meta-skill (allowed in L0)
      def kairos_meta_skill?(skill_id)
        kairos_meta_skills.include?(skill_id.to_sym)
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
            allowed = kairos_meta_skills.join(', ')
            return {
              valid: false,
              error: "Skill '#{skill_id}' is not allowed in L0. " \
                     "Allowed skills (from l0_governance): #{allowed}. " \
                     "To add a new skill type, first evolve the l0_governance skill."
            }
          end
        when :L0_constitution
          return { valid: false, error: 'L0 constitution (kairos.md) is immutable.' }
        end

        { valid: true }
      end

      # Map SkillSet layer symbols to internal layer keys
      SKILLSET_LAYER_MAP = {
        L0: :L0_law,
        L1: :L1,
        L2: :L2
      }.freeze

      private

      # Normalize a layer identifier: accept both internal keys (L0_constitution,
      # L0_law, L1, L2) and SkillSet shorthand symbols (:L0, :L1, :L2)
      def normalize_layer(layer)
        mapped = SKILLSET_LAYER_MAP[layer.to_sym]
        return mapped if mapped
        return layer if LAYERS.key?(layer)

        layer
      end

      def normalize_path(path)
        # Remove data directory prefix if present
        base_dir = KairosMcp.data_dir
        path = path.sub(base_dir, '').sub(%r{^/}, '')
        path
      end
    end
  end
end
