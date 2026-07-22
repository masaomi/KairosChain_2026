# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ConfidentialityGuard
      # Shared canonical serialization for policy pinning (CG-1/CG-3) and
      # content presentation/commitment (CG-3/CG-4). One encoder for both
      # so the pinned-policy hash and the content commitment can never
      # drift apart.
      #
      # Faithfulness rules (impl review R1):
      # - false and nil are preserved distinctly (no truthiness fallback).
      # - Hash keys are stringified; when a hash carries BOTH string and
      #   symbol forms of one name, BOTH entries are emitted (sorted by
      #   stringified key, original order as tiebreak) — dropping either
      #   would be a detection miss on a security guard. The output is a
      #   deterministic function of the presented object.
      module Canon
        module_function

        def canonical(obj)
          case obj
          when Hash
            entries = obj.map.with_index { |(k, v), i| [k.to_s, i, v] }
            entries.sort_by! { |key, i, _| [key, i] }
            "{#{entries.map { |key, _, v| "#{key.to_json}:#{canonical(v)}" }.join(',')}}"
          when Array
            "[#{obj.map { |v| canonical(v) }.join(',')}]"
          else
            obj.to_json
          end
        end

        # Deep string-keyed copy for classification (path extraction must
        # not depend on the caller's key form). Later entries win on
        # collision, matching Ruby hash assignment semantics.
        def stringify(obj)
          case obj
          when Hash
            obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify(v) }
          when Array
            obj.map { |v| stringify(v) }
          else
            obj
          end
        end
      end
    end
  end
end
