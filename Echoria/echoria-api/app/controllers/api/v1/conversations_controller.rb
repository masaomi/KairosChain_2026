module Api
  module V1
    class ConversationsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_conversation, only: %i[show]

      def index
        @conversations = current_user.conversations.order(created_at: :desc)
        render json: @conversations, each_serializer: ConversationSerializer
      end

      def create
        echo = Echo.find(params.require(:echo_id))
        authorize_echo_owner!(echo)

        @conversation = echo.conversations.build

        if @conversation.save
          render json: @conversation, serializer: ConversationDetailSerializer, status: :created
        else
          render json: { errors: @conversation.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def show
        authorize_echo_owner!(@conversation.echo)
        render json: @conversation, serializer: ConversationDetailSerializer
      end

      private

      def set_conversation
        @conversation = EchoConversation.find(params[:id])
      end
    end
  end
end

class ConversationSerializer
  include JSONAPI::Serializer

  attribute :echo_id
  attribute :created_at
  attribute :updated_at
  attribute :message_count do |conversation|
    conversation.echo_messages.count
  end
end

class ConversationDetailSerializer
  include JSONAPI::Serializer

  attribute :echo_id
  attribute :created_at
  attribute :updated_at
  attribute :messages do |conversation|
    conversation.echo_messages.order(created_at: :asc).map do |msg|
      { id: msg.id, role: msg.role, content: msg.content, created_at: msg.created_at }
    end
  end
end
