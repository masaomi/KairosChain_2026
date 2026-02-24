module Api
  module V1
    class AuthController < ApplicationController
      def signup
        user = User.new(user_params)

        if user.save
          token = generate_jwt(user.id)
          render json: { user: user_response(user), token: token }, status: :created
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def login
        user = User.find_by(email: params[:email])

        if user&.authenticate(params[:password])
          token = generate_jwt(user.id)
          render json: { user: user_response(user), token: token }, status: :ok
        else
          render json: { error: "Invalid email or password" }, status: :unauthorized
        end
      end

      def google
        auth_hash = request.env["omniauth.auth"]

        unless auth_hash
          return render json: { error: "OAuth authentication failed" }, status: :unauthorized
        end

        user = User.find_or_create_from_oauth(auth_hash)
        token = generate_jwt(user.id)

        render json: { user: user_response(user), token: token }, status: :ok
      end

      private

      def user_params
        params.require(:user).permit(:email, :password, :password_confirmation, :name)
      end

      def user_response(user)
        {
          id: user.id,
          email: user.email,
          name: user.name,
          avatar_url: user.avatar_url,
          subscription_status: user.subscription_status
        }
      end

      def generate_jwt(user_id)
        payload = {
          user_id: user_id,
          exp: (Time.current + JWT_CONFIG[:exp_time].seconds).to_i
        }

        JWT.encode(payload, JWT_CONFIG[:secret], JWT_CONFIG[:algorithm])
      end
    end
  end
end
