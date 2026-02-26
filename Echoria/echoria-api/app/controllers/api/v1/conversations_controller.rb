module Api
  module V1
    class ConversationsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_conversation, only: %i[show]

      def index
        echo = Echo.find(params[:echo_id]) if params[:echo_id]
        scope = echo ? echo.conversations : current_user.conversations
        scope = scope.with_partner(params[:partner]) if params[:partner].present?
        @conversations = scope.order(created_at: :desc)
        render json: @conversations, each_serializer: ConversationSerializer
      end

      def create
        echo = Echo.find(params.require(:echo_id))
        authorize_echo_owner!(echo)

        partner = params[:partner] || "echo"

        # Validate partner access
        if partner == "tiara"
          unless echo.story_sessions.where(chapter: "chapter_1", status: "completed").exists?
            return render json: {
              error: "第一章を完了するとティアラとの会話が解放されます"
            }, status: :forbidden
          end
        end

        @conversation = echo.conversations.build(partner: partner)

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
  attribute :partner
  attribute :created_at
  attribute :updated_at
  attribute :message_count do |conversation|
    conversation.echo_messages.count
  end
end

class ConversationDetailSerializer
  include JSONAPI::Serializer

  attribute :echo_id
  attribute :partner
  attribute :created_at
  attribute :updated_at
  attribute :messages do |conversation|
    conversation.echo_messages.order(created_at: :asc).map do |msg|
      { id: msg.id, role: msg.role, content: msg.content, created_at: msg.created_at }
    end
  end
end
