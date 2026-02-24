class ApplicationController < ActionController::API
  include ActionController::Helpers

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found
  rescue_from ActionController::ParameterMissing, with: :parameter_missing
  rescue_from StandardError, with: :internal_error

  protected

  def authenticate_user!
    token = extract_token
    raise Unauthorized, "Missing or invalid authorization header" unless token

    payload = decode_jwt(token)
    raise Unauthorized, "Invalid token" unless payload

    @current_user = User.find_by(id: payload["user_id"])
    raise Unauthorized, "User not found" unless @current_user
  end

  def current_user
    @current_user
  end

  def authorize_echo_owner!(echo)
    raise Forbidden, "Not authorized to access this echo" unless echo.user_id == current_user.id
  end

  private

  def extract_token
    auth_header = request.headers["Authorization"]
    auth_header&.split(" ")&.last
  end

  def decode_jwt(token)
    return nil unless token

    begin
      decoded = JWT.decode(
        token,
        JWT_CONFIG[:secret],
        true,
        algorithm: JWT_CONFIG[:algorithm]
      )
      decoded[0].with_indifferent_access
    rescue JWT::DecodeError, JWT::ExpiredSignature
      nil
    end
  end

  def record_not_found(exception)
    render json: { error: "Resource not found", details: exception.message }, status: :not_found
  end

  def parameter_missing(exception)
    render json: { error: "Missing required parameter", details: exception.message }, status: :bad_request
  end

  def internal_error(exception)
    Sentry.capture_exception(exception) if defined?(Sentry)

    render json: {
      error: "Internal server error",
      details: Rails.env.development? ? exception.message : nil
    }, status: :internal_server_error
  end

  class Unauthorized < StandardError; end
  class Forbidden < StandardError; end
end
