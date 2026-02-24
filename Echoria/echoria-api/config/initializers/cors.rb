# CORS configuration for Echoria API

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    if Rails.env.development?
      # Development: allow localhost
      origins "localhost:3000", "localhost:3001", "127.0.0.1:3000", "127.0.0.1:3001"
    else
      # Production: use environment variable
      allowed = ENV["ALLOWED_ORIGINS"]&.split(",")&.map(&:strip) || []
      origins(*allowed) if allowed.any?
    end

    resource "*",
             headers: :any,
             methods: %i[get post put patch delete options head]
  end
end
