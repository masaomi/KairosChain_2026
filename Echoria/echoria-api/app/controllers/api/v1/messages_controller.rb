module Api
  module V1
    class MessagesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_conversation
      before_action :authorize_conversation_owner!

      def index
        @messages = @conversation.echo_messages.order(created_at: :asc)
        render json: @messages, each_serializer: MessageSerializer
      end

      def create
        message_params = params.require(:message).permit(:content)

        # Add user message
        user_message = @conversation.add_message("user", message_params[:content])

        # Route to appropriate dialogue service based on partner
        response = if @conversation.tiara_conversation?
          TiaraDialogueService.new(@conversation.echo, @conversation).call(message_params[:content])
        else
          DialogueService.new(@conversation.echo, @conversation).call(message_params[:content])
        end

        # Add assistant message
        assistant_message = @conversation.add_message("assistant", response)

        render json: {
          user_message: user_message,
          assistant_message: assistant_message
        }, status: :created
      end

      private

      def set_conversation
        @conversation = EchoConversation.find(params[:conversation_id])
      end

      def authorize_conversation_owner!
        authorize_echo_owner!(@conversation.echo)
      end
    end
  end
end

class MessageSerializer
  include JSONAPI::Serializer

  attribute :role
  attribute :content
  attribute :created_at
end
