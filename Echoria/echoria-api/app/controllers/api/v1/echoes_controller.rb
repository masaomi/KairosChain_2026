module Api
  module V1
    class EchoesController < ApplicationController
      before_action :authenticate_user!
      before_action :set_echo, only: %i[show update destroy export_skills chain_status]

      def index
        @echoes = current_user.echoes.includes(:story_sessions).order(created_at: :desc)
        render json: @echoes.map { |e| echo_list_json(e) }
      end

      def create
        @echo = current_user.echoes.build(echo_params)

        if @echo.save
          begin
            EchoInitializerService.new(@echo).call
          rescue StandardError => e
            Rails.logger.error("[EchoesController] Initializer failed but Echo created: #{e.message}")
          end
          render json: echo_detail_json(@echo), status: :created
        else
          render json: { errors: @echo.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def show
        render json: echo_detail_json(@echo)
      end

      def update
        if @echo.update(echo_params)
          render json: echo_detail_json(@echo)
        else
          render json: { errors: @echo.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @echo.destroy
        render json: { message: "Echo destroyed" }, status: :ok
      end

      # GET /api/v1/echoes/:id/chain_status
      # Returns KairosChain blockchain summary for this Echo.
      def chain_status
        bridge = @echo.kairos_chain

        unless bridge&.available?
          return render json: {
            available: false,
            blocks: 0,
            recent_actions: []
          }, status: :ok
        end

        blocks = bridge.chain_blocks
        actions = bridge.action_history(limit: 10)

        render json: {
          available: true,
          blocks: blocks.length,
          integrity: bridge.verify_chain,
          recent_actions: actions.map { |a|
            {
              action: a[:action],
              timestamp: a[:timestamp],
              details: a[:details]
            }
          }
        }, status: :ok
      rescue StandardError => e
        Rails.logger.warn("[ChainStatus] #{e.message}")
        render json: { available: false, blocks: 0, recent_actions: [] }, status: :ok
      end

      # GET /api/v1/echoes/:id/export_skills
      # Downloads the Echo's SkillSet in KairosChain-compatible format.
      def export_skills
        unless @echo.crystallized?
          return render json: {
            error: "結晶化が完了していないエコーはエクスポートできません"
          }, status: :unprocessable_entity
        end

        export_data = SkillExportService.new(@echo).call
        render json: export_data, status: :ok
      end

      private

      def set_echo
        @echo = Echo.find(params[:id])
        authorize_echo_owner!(@echo)
      end

      def echo_params
        params.require(:echo).permit(:name, :avatar_url, personality: {})
      end

      # Flat JSON for echo list (index)
      def echo_list_json(echo)
        session = echo.story_sessions.order(updated_at: :desc).first
        {
          id: echo.id,
          name: echo.name,
          status: echo.status,
          avatar_url: echo.avatar_url,
          personality: echo.personality,
          created_at: echo.created_at,
          updated_at: echo.updated_at,
          story_progress: session ? {
            chapter: session.chapter,
            status: session.status,
            scene_count: session.scene_count,
            session_id: session.id
          } : nil
        }
      end

      # Flat JSON for echo detail (show/create/update)
      def echo_detail_json(echo)
        {
          id: echo.id,
          name: echo.name,
          status: echo.status,
          avatar_url: echo.avatar_url,
          personality: echo.personality,
          created_at: echo.created_at,
          updated_at: echo.updated_at,
          story_sessions: echo.story_sessions.map { |s|
            { id: s.id, chapter: s.chapter, status: s.status }
          },
          chapter_1_completed: echo.story_sessions.where(chapter: "chapter_1", status: "completed").exists?
        }
      end
    end
  end
end

class EchoSerializer
  include JSONAPI::Serializer

  attribute :name
  attribute :status
  attribute :avatar_url
  attribute :personality
  attribute :created_at
  attribute :updated_at
  attribute :story_progress do |echo|
    session = echo.story_sessions.order(updated_at: :desc).first
    if session
      {
        chapter: session.chapter,
        status: session.status,
        scene_count: session.scene_count,
        session_id: session.id
      }
    end
  end
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
