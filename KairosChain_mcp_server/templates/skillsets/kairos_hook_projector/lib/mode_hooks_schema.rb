# frozen_string_literal: true

require 'json'

module KairosMcp
  module SkillSets
    module KairosHookProjector
      # A validator that reads the schema rather than restating it.
      #
      # Stage 1 DoD-S1-7 and Inv-6 require the record producer and the record
      # schema to share one source of truth, with drift a compile-time error.
      # A hand-written checker restating the schema's rules in Ruby is exactly
      # the drift those clauses forbid, so this walks `_schema.json` itself.
      #
      # It is not a general JSON Schema implementation. It covers the draft-04
      # constructs the two shipped schemas actually use, and — this is the
      # important part — it REFUSES a schema using anything it does not
      # implement, rather than passing the document by silently ignoring the
      # construct. A validator that quietly skips `pattern` is worse than no
      # validator: it reports success it did not establish.
      #
      # `json-schema` is deliberately not used: it is absent from the gemspec
      # entirely, so a shipped SkillSet requiring it would break on any machine
      # that had not installed it for unrelated reasons.
      module ModeHooksSchema
        SUPPORTED_KEYWORDS = %w[
          $schema $id title description type required properties
          additionalProperties items enum pattern minLength minItems
          uniqueItems default minimum maximum patternProperties
        ].freeze

        Result = Struct.new(:valid, :errors, keyword_init: true) do
          def valid?
            valid
          end

          def message
            errors.join('; ')
          end
        end

        module_function

        # @return [Result] never raises on a malformed document
        def validate(document, schema)
          unsupported = unsupported_keywords(schema)
          unless unsupported.empty?
            return Result.new(valid: false,
                              errors: ["schema uses unimplemented keywords: #{unsupported.join(', ')}"])
          end

          errors = []
          check(document, schema, '#', errors)
          Result.new(valid: errors.empty?, errors: errors)
        rescue StandardError => e
          # Fail closed: a validator that raises must not be read as a pass.
          Result.new(valid: false, errors: ["validator error: #{e.class}: #{e.message}"])
        end

        def load_schema(path)
          JSON.parse(File.read(path))
        end

        # Walks the whole schema so an unimplemented construct is caught before
        # any document is judged, not when a document happens to reach it.
        def unsupported_keywords(node, found = [])
          case node
          when Hash
            if schema_node?(node)
              found.concat(node.keys - SUPPORTED_KEYWORDS)
            end
            node.each_value { |v| unsupported_keywords(v, found) }
          when Array
            node.each { |v| unsupported_keywords(v, found) }
          end
          found.uniq
        end

        def schema_node?(node)
          node.is_a?(Hash) && node.keys.any? { |k| %w[type properties items enum required].include?(k) }
        end

        def check(value, schema, path, errors)
          return if schema.nil? || schema == true

          check_type(value, schema, path, errors)
          return unless errors.empty? || errors.none? { |e| e.start_with?("#{path}: type") }

          check_enum(value, schema, path, errors)
          check_string(value, schema, path, errors)
          check_number(value, schema, path, errors)
          check_object(value, schema, path, errors)
          check_array(value, schema, path, errors)
        end

        def check_number(value, schema, path, errors)
          return unless value.is_a?(Numeric)

          if schema['minimum'] && value < schema['minimum']
            errors << "#{path}: #{value} is below minimum #{schema['minimum']}"
          end
          return unless schema['maximum'] && value > schema['maximum']

          errors << "#{path}: #{value} is above maximum #{schema['maximum']}"
        end

        TYPE_TESTS = {
          'object' => ->(v) { v.is_a?(Hash) },
          'array' => ->(v) { v.is_a?(Array) },
          'string' => ->(v) { v.is_a?(String) },
          'integer' => ->(v) { v.is_a?(Integer) },
          'number' => ->(v) { v.is_a?(Numeric) },
          'boolean' => ->(v) { v == true || v == false },
          'null' => ->(v) { v.nil? }
        }.freeze

        def check_type(value, schema, path, errors)
          types = Array(schema['type'])
          return if types.empty?

          return if types.any? { |t| TYPE_TESTS.fetch(t, ->(_) { false }).call(value) }

          errors << "#{path}: type is #{ruby_type(value)}, expected #{types.join(' or ')}"
        end

        def ruby_type(value)
          case value
          when Hash then 'object'
          when Array then 'array'
          when String then 'string'
          when Integer then 'integer'
          when Numeric then 'number'
          when true, false then 'boolean'
          when nil then 'null'
          else value.class.name
          end
        end

        def check_enum(value, schema, path, errors)
          return unless schema.key?('enum')
          return if schema['enum'].include?(value)

          errors << "#{path}: #{value.inspect} is not one of #{schema['enum'].inspect}"
        end

        def check_string(value, schema, path, errors)
          return unless value.is_a?(String)

          if schema['minLength'] && value.length < schema['minLength']
            errors << "#{path}: shorter than minLength #{schema['minLength']}"
          end
          return unless schema['pattern']

          errors << "#{path}: does not match #{schema['pattern']}" unless
            Regexp.new(schema['pattern']).match?(value)
        end

        def check_object(value, schema, path, errors)
          return unless value.is_a?(Hash)

          Array(schema['required']).each do |key|
            errors << "#{path}: missing required property '#{key}'" unless value.key?(key)
          end

          properties = schema['properties'] || {}
          patterned = schema['patternProperties'] || {}
          additional = schema.key?('additionalProperties') ? schema['additionalProperties'] : true

          value.each do |key, child|
            matching = patterned.find { |pattern, _| Regexp.new(pattern).match?(key) }
            if properties.key?(key)
              check(child, properties[key], "#{path}/#{key}", errors)
            elsif matching
              check(child, matching.last, "#{path}/#{key}", errors)
            elsif additional == false
              errors << "#{path}: property '#{key}' is not permitted"
            elsif additional.is_a?(Hash)
              check(child, additional, "#{path}/#{key}", errors)
            end
          end
        end

        def check_array(value, schema, path, errors)
          return unless value.is_a?(Array)

          if schema['minItems'] && value.size < schema['minItems']
            errors << "#{path}: fewer than minItems #{schema['minItems']}"
          end
          if schema['uniqueItems'] && value.size != value.uniq.size
            errors << "#{path}: items are not unique"
          end
          return unless schema['items']

          value.each_with_index { |item, i| check(item, schema['items'], "#{path}/#{i}", errors) }
        end
      end
    end
  end
end
