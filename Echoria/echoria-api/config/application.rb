require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

module Echoria
  class Application < Rails::Application
    config.load_defaults 8.0

    # API-only application
    config.api_only = true

    # Autoload lib/ for Echoria::KairosBridge
    config.autoload_lib(ignore: %w[tasks])

    # Generators configuration
    config.generators do |g|
      g.orm :active_record
      g.test_framework :rspec, fixture: false
      g.factory_bot dir: "spec/factories"
    end

    # Timezone
    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc

    # Custom configuration
    config.x.jwt.secret = if Rails.env.production?
                             ENV.fetch("JWT_SECRET") { raise "JWT_SECRET must be set in production" }
                           else
                             ENV.fetch("JWT_SECRET") { ENV.fetch("SECRET_KEY_BASE", "dev-secret-change-in-production") }
                           end
    config.x.anthropic.api_key = ENV.fetch("ANTHROPIC_API_KEY", nil)
    config.x.google_oauth.client_id = ENV.fetch("GOOGLE_CLIENT_ID", nil)
    config.x.google_oauth.client_secret = ENV.fetch("GOOGLE_CLIENT_SECRET", nil)
  end
end
