require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/bytes"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  # Cache
  config.cache_store = :memory_store, { size: 64.megabytes }

  # Logging
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info").to_sym
  config.log_tags = [:request_id]

  if ENV["RAILS_LOG_TO_STDOUT"].present?
    logger = ActiveSupport::Logger.new($stdout)
    logger.formatter = config.log_formatter
    config.logger = ActiveSupport::TaggedLogging.new(logger)
  end

  # SSL (disable with DISABLE_SSL=1 for local Docker testing)
  config.force_ssl = ENV["DISABLE_SSL"] != "1"
  config.ssl_options = { hsts: { subdomains: true } }

  # Active Record
  config.active_record.dump_schema_after_migration = false
  config.active_record.query_log_tags_enabled = true
  config.active_record.query_log_tags = [:request_id]

  # Sentry (conditional — only if gem loaded)
  if defined?(Sentry) && ENV["SENTRY_DSN"].present?
    Sentry.init do |sentry_config|
      sentry_config.dsn = ENV["SENTRY_DSN"]
      sentry_config.environment = "production"
      sentry_config.traces_sample_rate = 0.1
    end
  end
end
