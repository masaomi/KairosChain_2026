# frozen_string_literal: true

module ServiceGrant
  class RequestEnricher
    def initialize(service_name:)
      @service_name = service_name
    end

    def register!
      enricher = self
      KairosMcp::Protocol.register_filter(:service_grant_enricher) do |ctx|
        enricher.enrich(ctx)
      end
    end

    def unregister!
      KairosMcp::Protocol.unregister_filter(:service_grant_enricher)
    end

    def enrich(ctx)
      return ctx unless ctx
      ctx[:service] ||= @service_name
      ctx
    end
  end
end
