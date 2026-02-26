# Exports an Echo's SkillSet in KairosChain-compatible format.
#
# Generates a JSON bundle containing:
#   - Echo personality and archetype
#   - All evolved skills in KairosChain L1 knowledge format
#   - Story journey metadata
#   - Affinity state
#
# The output can be imported into a local KairosChain MCP server
# via the knowledge_update tool, bridging the Echoria story experience
# to a persistent AI companion on the user's machine.
#
class SkillExportService
  def initialize(echo)
    @echo = echo
    @session = echo.story_sessions.where(status: "completed").order(updated_at: :desc).first
  end

  def call
    {
      format: "kairoschain_skillset",
      version: "1.0",
      exported_at: Time.current.iso8601,
      echo: echo_metadata,
      skills: export_skills,
      knowledge: export_knowledge_entries,
      chain_summary: chain_summary
    }
  end

  private

  def echo_metadata
    {
      name: @echo.name,
      status: @echo.status,
      archetype: @echo.personality&.dig("primary_archetype"),
      secondary_traits: @echo.personality&.dig("secondary_traits") || [],
      character_description: @echo.personality&.dig("character_description"),
      affinities: @session&.affinity || @echo.personality&.dig("affinities") || {},
      story_arc: @echo.personality&.dig("story_arc"),
      created_at: @echo.created_at.iso8601
    }
  end

  def export_skills
    @echo.echo_skills.order(:layer, :created_at).map do |skill|
      {
        skill_id: skill.skill_id,
        title: skill.title,
        content: skill.content,
        layer: skill.layer,
        kairos_format: to_kairos_knowledge(skill)
      }
    end
  end

  # Convert an EchoSkill to KairosChain L1 knowledge format
  def to_kairos_knowledge(skill)
    {
      name: "echoria_#{skill.skill_id}",
      layer: "L1",
      content: build_skill_markdown(skill),
      tags: ["echoria", "echo:#{@echo.name}", skill.layer.downcase],
      metadata: {
        source: "echoria",
        echo_id: @echo.id,
        echo_name: @echo.name,
        original_layer: skill.layer,
        imported_at: nil # Set on import
      }
    }
  end

  def build_skill_markdown(skill)
    <<~MD
      # #{skill.title}

      #{skill.content}

      ## Origin
      - Echo: #{@echo.name}
      - Layer: #{skill.layer}
      - Source: Echoria story experience
      - Archetype: #{@echo.personality&.dig("primary_archetype") || "unknown"}
    MD
  end

  # Generate KairosChain knowledge entries for import
  def export_knowledge_entries
    entries = []

    # Echo personality as knowledge
    entries << {
      name: "echoria_personality_#{@echo.name.downcase.gsub(/\s+/, '_')}",
      layer: "L1",
      content: personality_knowledge_content,
      tags: ["echoria", "personality", "echo:#{@echo.name}"]
    }

    # Story journey as knowledge
    if @session
      entries << {
        name: "echoria_journey_#{@echo.name.downcase.gsub(/\s+/, '_')}",
        layer: "L1",
        content: journey_knowledge_content,
        tags: ["echoria", "journey", "echo:#{@echo.name}"]
      }
    end

    entries
  end

  def personality_knowledge_content
    affinities = @session&.affinity || {}
    archetype = @echo.personality&.dig("primary_archetype") || "Unknown"
    description = @echo.personality&.dig("character_description") || ""

    <<~MD
      # Echo Personality: #{@echo.name}

      ## Archetype
      #{archetype}

      ## Character
      #{description}

      ## Affinity Profile
      - Tiara Trust: #{affinities['tiara_trust'] || 50}/100
      - Logic/Empathy Balance: #{affinities['logic_empathy_balance'] || 0} (-50 to +50)
      - Name Memory Stability: #{affinities['name_memory_stability'] || 50}/100
      - Authority Resistance: #{affinities['authority_resistance'] || 0} (-50 to +50)
      - Fragments Collected: #{affinities['fragment_count'] || 0}

      ## Communication Style
      This Echo should reflect its personality when used as a KairosChain agent.
      The archetype and affinity values guide how the Echo approaches problems,
      communicates, and makes decisions.
    MD
  end

  def journey_knowledge_content
    return "" unless @session

    <<~MD
      # Story Journey: #{@echo.name}

      ## Chapter: #{@session.chapter}
      - Status: #{@session.status}
      - Scenes Experienced: #{@session.scene_count}
      - Completed: #{@session.updated_at&.iso8601}

      ## Skills Evolved
      #{@echo.echo_skills.map { |s| "- #{s.title} (#{s.layer})" }.join("\n")}

      ## Journey Notes
      This Echo was born through choices made in the Echoria story.
      Each skill represents a threshold crossed through lived experience.
    MD
  end

  def chain_summary
    bridge = @echo.kairos_chain
    return nil unless bridge&.available?

    {
      blocks: bridge.chain_blocks.length,
      integrity: bridge.verify_chain,
      last_action: bridge.action_history(limit: 1).first
    }
  rescue StandardError
    nil
  end
end
