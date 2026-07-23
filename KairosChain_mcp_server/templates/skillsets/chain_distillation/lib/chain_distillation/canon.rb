# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module ChainDistillation
      # Canonical serialization for commitments and claim-core hashing
      # (design v0.5 CD-2/CD-6). Same faithfulness rules as the guard's
      # Canon (impl review R1 lineage): false/nil preserved distinctly;
      # mixed string/symbol keys both emitted, sorted by stringified key
      # with original order as tiebreak. One encoder for designation
      # digests, artifact commitments, and claim-core commitments so no
      # two bindings can drift apart.
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
