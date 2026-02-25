# Sentry error monitoring for production
#
# Set SENTRY_DSN environment variable to enable.
# Without SENTRY_DSN, Sentry is silently disabled.
#
if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.breadcrumbs_logger = [:active_support_logger, :http_logger]
    config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_RATE", 0.1).to_f
    config.profiles_sample_rate = ENV.fetch("SENTRY_PROFILES_RATE", 0.1).to_f

    # Filter sensitive parameters
    config.send_default_pii = false

    # Environment tag
    config.environment = Rails.env

    # Release tracking
    config.release = "echoria@#{ENV.fetch('APP_VERSION', '0.1.0')}"

    # Exclude common noise
    config.excluded_exceptions += [
      "ActionController::RoutingError",
      "ActiveRecord::RecordNotFound"
    ]
  end
end
