# Converts personality quiz answers into initial affinity values.
#
# The quiz consists of 3 questions framed as Tiara's first contact
# with the Echo. Each answer shifts 1-2 affinity axes.
#
# Question themes:
#   Q1: Memory & sensation → name_memory_stability, logic_empathy_balance
#   Q2: Relationship distance → tiara_trust, authority_resistance
#   Q3: Worldview → logic_empathy_balance, fragment_count
#
class QuizAffinityService
  VALID_QUESTION_IDS = %w[q1 q2 q3].freeze

  # Delta tables keyed by question_id and answer_id.
  # Values are additive to DEFAULT_AFFINITY.
  ANSWER_DELTAS = {
    "q1" => {
      "a" => { "name_memory_stability" => 10 },
      "b" => { "logic_empathy_balance" => 10 },
      "c" => { "logic_empathy_balance" => -10, "name_memory_stability" => 5 }
    },
    "q2" => {
      "a" => { "tiara_trust" => 10 },
      "b" => { "authority_resistance" => 5, "tiara_trust" => -5 },
      "c" => { "authority_resistance" => 10 }
    },
    "q3" => {
      "a" => { "fragment_count" => 1, "logic_empathy_balance" => 5 },
      "b" => { "logic_empathy_balance" => -5 },
      "c" => { "logic_empathy_balance" => 10, "fragment_count" => 1 }
    }
  }.freeze

  def initialize(quiz_answers)
    @answers = normalize_answers(quiz_answers)
  end

  # Returns a complete affinity hash (base + quiz deltas)
  def call
    base = StorySession::DEFAULT_AFFINITY.dup
    accumulated_delta = {}

    @answers.each do |question_id, answer_id|
      delta = ANSWER_DELTAS.dig(question_id, answer_id)
      next unless delta

      delta.each do |axis, value|
        accumulated_delta[axis] = (accumulated_delta[axis] || 0) + value
      end
    end

    # Apply accumulated delta to base
    accumulated_delta.each do |axis, value|
      base[axis] = clamp_axis(axis, base[axis] + value)
    end

    base
  end

  # Returns only the delta (for display purposes)
  def delta_only
    result = {}
    @answers.each do |question_id, answer_id|
      delta = ANSWER_DELTAS.dig(question_id, answer_id)
      next unless delta

      delta.each do |axis, value|
        result[axis] = (result[axis] || 0) + value
      end
    end
    result
  end

  private

  def normalize_answers(raw)
    return {} unless raw.is_a?(Hash) || raw.is_a?(ActionController::Parameters)

    raw.to_h.each_with_object({}) do |(k, v), hash|
      key = k.to_s
      val = v.to_s.downcase
      hash[key] = val if VALID_QUESTION_IDS.include?(key) && %w[a b c].include?(val)
    end
  end

  def clamp_axis(axis, value)
    case axis
    when "tiara_trust", "name_memory_stability"
      value.clamp(0, 100)
    when "logic_empathy_balance", "authority_resistance"
      value.clamp(-50, 50)
    when "fragment_count"
      [value, 0].max
    else
      value
    end
  end
end
