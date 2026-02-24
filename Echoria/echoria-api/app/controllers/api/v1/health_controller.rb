module Api
  module V1
    class HealthController < ApplicationController
      def check
        render json: {
          status: "ok",
          timestamp: Time.current.iso8601,
          environment: Rails.env
        }
      end
    end
  end
end
