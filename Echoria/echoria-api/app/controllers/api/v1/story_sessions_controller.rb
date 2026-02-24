module Api
  module V1
    class StorySessionsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_story_session, only: %i[show choose generate_scene]
      before_action :set_echo, only: [:create]

      def create
        chapter = params.require(:chapter)
        first_beacon = StoryBeacon.in_chapter(chapter).ordered.first

        unless first_beacon
          return render json: { error: "Chapter not found" }, status: :not_found
        end

        @session = @echo.story_sessions.build(
          chapter: chapter,
          current_beacon_id: first_beacon.id,
          scene_count: 0,
          status: :active
        )

        if @session.save
          render json: @session, serializer: StorySessionDetailSerializer, status: :created
        else
          render json: { errors: @session.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def show
        render json: @session, serializer: StorySessionDetailSerializer
      end

      def choose
        choice_data = params.require(:choice)
        choice_index = choice_data.require(:index)
        beacon_choices = @session.current_beacon.choices

        unless choice_index.between?(0, beacon_choices.length - 1)
          return render json: { error: "Invalid choice index" }, status: :bad_request
        end

        selected_choice = beacon_choices[choice_index]

        result = StoryGeneratorService.new(@session, selected_choice).call

        scene = @session.story_scenes.build(
          scene_order: @session.scene_count + 1,
          scene_type: result[:scene_type],
          beacon_id: @session.current_beacon_id,
          narrative: result[:narrative],
          echo_action: result[:echo_action],
          user_choice: selected_choice["text"],
          affinity_delta: result[:affinity_delta]
        )

        if scene.save && @session.update(scene_count: @session.scene_count + 1)
          @session.add_affinity_delta(result[:affinity_delta])
          @session.save

          next_beacon = find_next_beacon(selected_choice)
          @session.update(current_beacon_id: next_beacon.id) if next_beacon

          render json: {
            scene: scene,
            session: @session,
            next_choices: next_beacon&.choices || []
          }, serializer: StorySessionResponseSerializer, status: :ok
        else
          render json: { errors: scene.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def generate_scene
        result = StoryGeneratorService.new(@session, nil).call

        scene = @session.story_scenes.build(
          scene_order: @session.scene_count + 1,
          scene_type: result[:scene_type],
          beacon_id: @session.current_beacon_id,
          narrative: result[:narrative],
          echo_action: result[:echo_action],
          affinity_delta: result[:affinity_delta]
        )

        if scene.save
          @session.update(scene_count: @session.scene_count + 1)
          @session.add_affinity_delta(result[:affinity_delta])
          @session.save

          render json: scene, serializer: StorySceneSerializer, status: :created
        else
          render json: { errors: scene.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_story_session
        @session = StorySession.find(params[:id])
        authorize_echo_owner!(@session.echo)
      end

      def set_echo
        @echo = Echo.find(params.require(:echo_id))
        authorize_echo_owner!(@echo)
      end

      def find_next_beacon(choice)
        next_beacon_id = choice["next_beacon_id"]
        return nil unless next_beacon_id

        StoryBeacon.find(next_beacon_id)
      end
    end
  end
end

class StorySessionSerializer
  include JSONAPI::Serializer

  attribute :chapter
  attribute :scene_count
  attribute :affinity
  attribute :status
  attribute :created_at
  attribute :updated_at
end

class StorySessionDetailSerializer
  include JSONAPI::Serializer

  attribute :chapter
  attribute :scene_count
  attribute :affinity
  attribute :status
  attribute :created_at
  attribute :updated_at
  attribute :current_beacon do |session|
    session.current_beacon&.to_narrative
  end
  attribute :recent_scenes do |session|
    session.story_scenes.ordered.last(5).map(&:to_narrative)
  end
end

class StorySceneSerializer
  include JSONAPI::Serializer

  attribute :scene_order
  attribute :scene_type
  attribute :narrative
  attribute :echo_action
  attribute :user_choice
  attribute :affinity_delta
  attribute :created_at
end

class StorySessionResponseSerializer
  include JSONAPI::Serializer

  attribute :message
  attribute :scene
  attribute :session
end
