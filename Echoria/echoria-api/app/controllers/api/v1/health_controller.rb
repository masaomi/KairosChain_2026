module Api
  module V1
    class HealthController < ApplicationController
      def check
        ActiveRecord::Base.connection.execute("SELECT 1")

        render json: {
          status: "ok",
          timestamp: Time.current.iso8601,
          environment: Rails.env,
          database: "connected"
        }
      rescue StandardError => e
        render json: {
          status: "error",
          timestamp: Time.current.iso8601,
          error: e.message
        }, status: :service_unavailable
      end
    end
  end
end
