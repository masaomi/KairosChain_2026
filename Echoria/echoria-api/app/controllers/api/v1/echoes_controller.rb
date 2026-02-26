module Api
  module V1
    class EchoesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_echo, only: %i[show update destroy]

      def index
        @echoes = current_user.echoes.includes(:story_sessions).order(created_at: :desc)
        render json: @echoes, each_serializer: EchoSerializer
      end

      def create
        @echo = current_user.echoes.build(echo_params)

        if @echo.save
          EchoInitializerService.new(@echo).call
          render json: @echo, serializer: EchoDetailSerializer, status: :created
        else
          render json: { errors: @echo.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def show
        render json: @echo, serializer: EchoDetailSerializer
      end

      def update
        if @echo.update(echo_params)
          render json: @echo, serializer: EchoDetailSerializer
        else
          render json: { errors: @echo.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @echo.destroy
        render json: { message: "Echo destroyed" }, status: :ok
      end

      private

      def set_echo
        @echo = Echo.find(params[:id])
        authorize_echo_owner!(@echo)
      end

      def echo_params
        params.require(:echo).permit(:name, :avatar_url, personality: {})
      end
    end
  end
end

class EchoSerializer
  include JSONAPI::Serializer

  attribute :name
  attribute :status
  attribute :avatar_url
  attribute :created_at
  attribute :updated_at
end

class EchoDetailSerializer
  include JSONAPI::Serializer

  attribute :name
  attribute :status
  attribute :avatar_url
  attribute :personality
  attribute :created_at
  attribute :updated_at
  attribute :story_sessions do |echo|
    echo.story_sessions.map { |s| { id: s.id, chapter: s.chapter, status: s.status } }
  end
  attribute :chapter_1_completed do |echo|
    echo.story_sessions.where(chapter: "chapter_1", status: "completed").exists?
  end
end
