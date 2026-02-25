# Validates AI-generated narrative content against Echoria world rules.
#
# Four guard layers:
#   1. WorldVocabulary — forbidden/required term enforcement
#   2. CharacterVoice  — Tiara speech pattern & trust-level consistency
#   3. Timeline        — scene progression & pacing validation
#   4. ProhibitedTransition — prevents lore-breaking plot elements
#
# Usage:
#   result = LoreConstraintLayer.validate(generated_content, session)
#   result[:valid]      # => true/false
#   result[:violations] # => array of violation descriptions
#   result[:sanitized]  # => cleaned content (forbidden terms removed)
#
class LoreConstraintLayer
  FORBIDDEN_TERMS = %w[
    magic spell mana wizard sorcery enchantment
    chosen\ one special\ powers
    魔法 魔力 呪文 魔術師 選ばれし者
  ].freeze

  FORBIDDEN_COMBINATIONS = [
    %w[呼応石 magic],
    %w[呼応石 魔法],
    %w[名折れ curse],
    %w[名折れ 呪い],
    %w[カケラ artifact],
    %w[カケラ アーティファクト],
    %w[呼応 power-up],
    %w[呼応 パワーアップ]
  ].freeze

  PROHIBITED_NARRATIVE_ELEMENTS = [
    /(?:選ばれし|特別な力を持つ|唯一の救世主)/,
    /(?:魔法|呪文|魔術|マナ)/,
    /(?:レベルアップ|経験値|ステータス)/
  ].freeze

  class << self
    # Main entry point: validates generated content against all layers
    def validate(content, story_session)
      violations = []
      sanitized = content.dup

      # Layer 1: WorldVocabulary
      vocab_result = check_vocabulary(content)
      violations.concat(vocab_result[:violations])
      sanitized = vocab_result[:sanitized]

      # Layer 2: CharacterVoice
      voice_result = check_character_voice(content, story_session)
      violations.concat(voice_result[:violations])

      # Layer 3: Timeline
      timeline_result = check_timeline(content, story_session)
      violations.concat(timeline_result[:violations])

      # Layer 4: ProhibitedTransition
      transition_result = check_prohibited_transitions(content)
      violations.concat(transition_result[:violations])

      {
        valid: violations.empty?,
        violations: violations,
        sanitized: sanitized,
        layer_results: {
          vocabulary: vocab_result,
          character_voice: voice_result,
          timeline: timeline_result,
          prohibited_transition: transition_result
        }
      }
    end

    # Convenience: validate and return sanitized content, logging violations
    def validate!(content, story_session)
      result = validate(content, story_session)

      unless result[:valid]
        Rails.logger.warn(
          "[LoreConstraint] #{result[:violations].length} violations: " \
          "#{result[:violations].join('; ')}"
        )
      end

      result
    end

    private

    # === Layer 1: WorldVocabulary ===
    # Checks for forbidden terms and removes them from narrative
    def check_vocabulary(content)
      violations = []
      sanitized = content.dup

      FORBIDDEN_TERMS.each do |term|
        if content.match?(/#{Regexp.escape(term)}/i)
          violations << "[Vocabulary] Forbidden term detected: '#{term}'"
          # Replace forbidden term with lore-appropriate alternatives
          sanitized = sanitized.gsub(/#{Regexp.escape(term)}/i, vocabulary_replacement(term))
        end
      end

      FORBIDDEN_COMBINATIONS.each do |pair|
        if content.include?(pair[0]) && content.match?(/#{Regexp.escape(pair[1])}/i)
          violations << "[Vocabulary] Forbidden combination: '#{pair[0]}' + '#{pair[1]}'"
        end
      end

      { violations: violations, sanitized: sanitized }
    end

    # === Layer 2: CharacterVoice ===
    # Validates Tiara's speech patterns match trust level
    def check_character_voice(content, story_session)
      violations = []
      affinity = story_session.affinity || {}
      trust = affinity["tiara_trust"] || 50

      # Tiara should use formal register at low trust
      if trust < 30
        # Check for overly casual speech patterns in Tiara dialogue
        if content.match?(/ティアラ.*(?:だよ|だね|じゃん|でしょ[^う])/)
          violations << "[CharacterVoice] Tiara uses casual speech at low trust (#{trust})"
        end
      end

      # Tiara should not reveal deep knowledge at low trust
      if trust < 40
        if content.match?(/ティアラ.*(?:本当の名前|真実を|すべてを教え)/)
          violations << "[CharacterVoice] Tiara reveals deep knowledge at low trust (#{trust})"
        end
      end

      # Tiara should not cry easily — only at very high trust
      if trust < 70
        if content.match?(/ティアラ.*(?:涙を流|泣き(?:始|出)|泣いて)/)
          violations << "[CharacterVoice] Tiara cries at insufficient trust level (#{trust})"
        end
      end

      # にゃ should be rare — only in emotional overwhelm
      if content.scan(/にゃ/).length > 2
        violations << "[CharacterVoice] Excessive 'にゃ' usage (Tiara is not a cute mascot)"
      end

      { violations: violations }
    end

    # === Layer 3: Timeline ===
    # Validates scene pacing and chapter progression
    def check_timeline(content, story_session)
      violations = []

      scene_count = story_session.scene_count || 0
      chapter = story_session.chapter

      # First few scenes should not have major revelations
      if scene_count < 3
        if content.match?(/(?:すべてを思い出|真実が|本当の名前)/)
          violations << "[Timeline] Major revelation too early (scene #{scene_count})"
        end
      end

      # Chapter 1 should not reference chapter 2+ content
      if chapter == "chapter_1"
        if content.match?(/(?:音の砂漠|第二章|次の世界)/)
          violations << "[Timeline] Chapter 2 content referenced in Chapter 1"
        end
      end

      # Prevent rushed pacing — check narrative density
      sentences = content.split(/[。！？\n]/).reject(&:blank?)
      if sentences.length > 8
        violations << "[Timeline] Scene too dense (#{sentences.length} sentences, max 8)"
      end

      { violations: violations }
    end

    # === Layer 4: ProhibitedTransition ===
    # Blocks lore-breaking narrative elements
    def check_prohibited_transitions(content)
      violations = []

      PROHIBITED_NARRATIVE_ELEMENTS.each do |pattern|
        if content.match?(pattern)
          violations << "[ProhibitedTransition] Lore-breaking element: #{pattern.source}"
        end
      end

      # No complete resurrection without cost
      if content.match?(/(?:完全に蘇|完全に復活|元に戻った)/)
        violations << "[ProhibitedTransition] Costless resurrection detected"
      end

      # No sudden power-ups
      if content.match?(/(?:突然.*力が|急に.*強く|一気に.*目覚め)/)
        violations << "[ProhibitedTransition] Sudden power-up detected"
      end

      # No fourth-wall breaking
      if content.match?(/(?:プレイヤー|ゲーム|スコア|ポイント)/)
        violations << "[ProhibitedTransition] Fourth-wall breaking detected"
      end

      { violations: violations }
    end

    # Returns lore-appropriate replacement for forbidden terms
    def vocabulary_replacement(term)
      case term.downcase
      when "magic", "魔法"
        "呼応の力"
      when "spell", "呪文"
        "呼びかけ"
      when "mana", "魔力"
        "呼応の波動"
      when "wizard", "魔術師"
        "呼応の導き手"
      when "sorcery", "魔術"
        "深い呼応"
      when "enchantment"
        "呼応の結晶"
      when "chosen one", "選ばれし者"
        "呼応に導かれし者"
      when "special powers"
        "深い呼応の力"
      else
        "呼応"
      end
    end
  end
end
