# frozen_string_literal: true

module Hestia
  module Chain
    module Integrations
      class Base
        attr_reader :client

        def initialize(client:)
          @client = client
        end

        def ready?
          @client.status[:backend_ready]
        end

        def stats
          { integration: self.class.name, client: @client.stats }
        end

        protected

        def build_anchor(anchor_type:, source_id:, data:, **options)
          data_hash = calculate_hash(data)
          Core::Anchor.new(
            anchor_type: anchor_type,
            source_id: source_id,
            data_hash: data_hash,
            **options
          )
        end

        def calculate_hash(data)
          content = case data
                    when String then data
                    when Hash then data.to_json
                    else data.to_s
                    end
          Digest::SHA256.hexdigest(content)
        end
      end
    end
  end
end
