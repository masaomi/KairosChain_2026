require 'json'
require 'time'

module KairosMcp
  module KairosChain
    class SkillTransition
      attr_reader :skill_id, :prev_ast_hash, :next_ast_hash, :diff_hash, 
                  :actor, :agent_id, :timestamp, :reason_ref
      
      def initialize(skill_id:, prev_ast_hash:, next_ast_hash:, diff_hash:, 
                     actor: "AI", agent_id: "Kairos", timestamp: Time.now.iso8601, reason_ref: nil)
        @skill_id = skill_id
        @prev_ast_hash = prev_ast_hash
        @next_ast_hash = next_ast_hash
        @diff_hash = diff_hash
        @actor = actor
        @agent_id = agent_id
        @timestamp = timestamp
        @reason_ref = reason_ref
      end
      
      def to_h
        {
          skill_id: @skill_id,
          prev_ast_hash: @prev_ast_hash,
          next_ast_hash: @next_ast_hash,
          diff_hash: @diff_hash,
          actor: @actor,
          agent_id: @agent_id,
          timestamp: @timestamp,
          reason_ref: @reason_ref
        }
      end
      
      def to_json(*args)
        to_h.to_json(*args)
      end
      
      def self.from_json(json_str)
        data = JSON.parse(json_str, symbolize_names: true)
        new(**data)
      end
    end
  end
end
