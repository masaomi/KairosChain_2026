# Rate limiting for Echoria API
#
# Limits:
#   - General API: 60 req/min per IP
#   - Story generation: 20 req/min per user (AI-intensive)
#   - Auth endpoints: 10 req/min per IP (brute-force protection)
#
class Rack::Attack
  # General API rate limit
  throttle("api/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/")
  end

  # Story generation (AI calls are expensive)
  throttle("story/user", limit: 20, period: 1.minute) do |req|
    if req.path.match?(%r{/story_sessions/.+/(choose|generate_scene)}) && req.post?
      # Extract user from JWT token
      token = req.env["HTTP_AUTHORIZATION"]&.sub(/^Bearer /, "")
      if token
        begin
          payload = JWT.decode(token, Rails.application.config.x.jwt[:secret], true, algorithm: "HS256")
          payload[0]["user_id"]
        rescue JWT::DecodeError
          nil
        end
      end
    end
  end

  # Auth endpoint protection
  throttle("auth/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/auth/") && req.post?
  end

  # Block suspicious requests
  blocklist("block/bad-paths") do |req|
    req.path.match?(%r{\.(php|asp|aspx|jsp|cgi)$})
  end

  # Custom response for throttled requests
  self.throttled_responder = lambda do |req|
    [429, { "Content-Type" => "application/json" },
     [{ error: "リクエスト制限に達しました。しばらくお待ちください。" }.to_json]]
  end
end
