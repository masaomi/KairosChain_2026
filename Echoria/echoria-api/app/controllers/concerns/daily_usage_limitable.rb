# Enforces daily API usage limits per user.
#
# Uses the daily_api_usage and daily_api_reset_at columns on User
# to track and limit AI-intensive operations (scene generation, chat).
# Limits are configured via environment variables:
#   DAILY_SCENE_LIMIT (default: 50) — for story choose/generate_scene
#   DAILY_CHAT_LIMIT  (default: 100) — for chat messages
#
module DailyUsageLimitable
  extend ActiveSupport::Concern

  private

  def check_daily_usage!(limit_type = :scene)
    return unless current_user

    reset_daily_counter_if_needed!

    limit = daily_limit_for(limit_type)
    if current_user.daily_api_usage >= limit
      render json: {
        error: "本日のAPI利用上限に達しました。明日またお試しください。",
        daily_limit: limit,
        usage: current_user.daily_api_usage
      }, status: :too_many_requests
      return false
    end

    true
  end

  def increment_daily_usage!
    return unless current_user

    current_user.increment!(:daily_api_usage)
  end

  def reset_daily_counter_if_needed!
    return unless current_user

    if current_user.daily_api_reset_at.nil? || current_user.daily_api_reset_at < Date.current
      current_user.update!(daily_api_usage: 0, daily_api_reset_at: Date.current)
    end
  end

  def daily_limit_for(limit_type)
    case limit_type
    when :scene
      (ENV["DAILY_SCENE_LIMIT"] || 50).to_i
    when :chat
      (ENV["DAILY_CHAT_LIMIT"] || 100).to_i
    else
      50
    end
  end
end
