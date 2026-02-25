module Api
  module V1
    class StorySessionsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_story_session, only: %i[show choose generate_scene]
      before_action :set_echo, only: [:create]

      # POST /api/v1/story_sessions
      # Starts a new story session for an Echo in a given chapter.
      def create
        chapter = params.require(:chapter)
        first_beacon = StoryBeacon.in_chapter(chapter).ordered.first

        unless first_beacon
          return render json: { error: "Chapter not found" }, status: :not_found
        end

        # Prevent duplicate active sessions in the same chapter
        existing = @echo.story_sessions.active_sessions.by_chapter(chapter).first
        if existing
          return render json: {
            error: "Active session already exists for this chapter",
            session_id: existing.id
          }, status: :conflict
        end

        @session = @echo.story_sessions.build(
          chapter: chapter,
          current_beacon_id: first_beacon.id,
          scene_count: 0,
          status: :active
        )

        if @session.save
          # Create the first beacon scene automatically
          navigator = BeaconNavigatorService.new(@session)
          navigator.create_beacon_scene!

          render json: session_detail_response(@session.reload), status: :created
        else
          render json: { errors: @session.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/story_sessions/:id
      def show
        render json: session_detail_response(@session)
      end

      # POST /api/v1/story_sessions/:id/choose
      # Player makes a choice at the current beacon.
      def choose
        choice_index = params.require(:choice_index).to_i
        navigator = BeaconNavigatorService.new(@session)

        # Validate choice
        unless navigator.valid_choice?(choice_index)
          return render json: { error: "Invalid choice index" }, status: :bad_request
        end

        selected_choice = navigator.choice_at(choice_index)
        affinity_calc = AffinityCalculatorService.new(@session)

        # Generate AI scene based on the choice
        result = StoryGeneratorService.new(@session, selected_choice).call

        # Validate generated content against lore constraints
        lore_check = LoreConstraintLayer.validate!(result[:narrative], @session)
        narrative_text = lore_check[:valid] ? result[:narrative] : lore_check[:sanitized]

        # Create the scene
        scene = @session.story_scenes.create!(
          scene_order: @session.scene_count + 1,
          scene_type: result[:scene_type],
          beacon_id: @session.current_beacon_id,
          narrative: narrative_text,
          echo_action: result[:echo_action],
          user_choice: selected_choice["choice_text"] || selected_choice["text"],
          decision_actor: :player,
          affinity_delta: result[:affinity_delta]
        )

        @session.update!(scene_count: @session.scene_count + 1)

        # Apply affinity changes (beacon delta is authoritative, AI delta is supplementary)
        affinity_calc.apply_combined(selected_choice, result)

        # Advance to next beacon
        next_beacon = navigator.advance!(selected_choice)

        # If we advanced to a new beacon, create a beacon scene for it
        if next_beacon
          navigator.create_beacon_scene!
        end

        # Check for chapter end
        if navigator.chapter_end? && affinity_calc.crystallization_ready?
          @session.reload
          render json: {
            scene: scene_response(scene),
            session: session_summary(@session),
            next_choices: next_beacon&.choices || [],
            chapter_end: true,
            crystallization_available: true
          }, status: :ok
        else
          @session.reload
          render json: {
            scene: scene_response(scene),
            session: session_summary(@session),
            next_choices: next_beacon&.choices || @session.current_beacon&.choices || [],
            chapter_end: navigator.chapter_end?,
            beacon_progress: navigator.beacon_progress
          }, status: :ok
        end
      end

      # POST /api/v1/story_sessions/:id/generate_scene
      # Generates an AI scene without explicit player choice (auto-progression).
      def generate_scene
        result = StoryGeneratorService.new(@session, nil).call

        # Lore validation
        lore_check = LoreConstraintLayer.validate!(result[:narrative], @session)
        narrative_text = lore_check[:valid] ? result[:narrative] : lore_check[:sanitized]

        scene = @session.story_scenes.create!(
          scene_order: @session.scene_count + 1,
          scene_type: result[:scene_type],
          beacon_id: @session.current_beacon_id,
          narrative: narrative_text,
          echo_action: result[:echo_action],
          decision_actor: :system,
          affinity_delta: result[:affinity_delta]
        )

        @session.update!(scene_count: @session.scene_count + 1)

        # Apply generated affinity delta
        AffinityCalculatorService.new(@session).apply_generated_delta(result)

        @session.reload
        render json: {
          scene: scene_response(scene),
          session: session_summary(@session)
        }, status: :created
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

      # --- Response Helpers ---

      def session_detail_response(session)
        {
          id: session.id,
          chapter: session.chapter,
          scene_count: session.scene_count,
          affinity: session.affinity,
          status: session.status,
          created_at: session.created_at,
          current_beacon: session.current_beacon&.to_narrative,
          recent_scenes: session.story_scenes.ordered.last(5).map { |s| scene_response(s) },
          affinity_summary: AffinityCalculatorService.new(session).affinity_summary
        }
      end

      def session_summary(session)
        {
          id: session.id,
          chapter: session.chapter,
          scene_count: session.scene_count,
          affinity: session.affinity,
          status: session.status,
          affinity_summary: AffinityCalculatorService.new(session).affinity_summary
        }
      end

      def scene_response(scene)
        {
          id: scene.id,
          order: scene.scene_order,
          type: scene.scene_type,
          narrative: scene.narrative,
          echo_action: scene.echo_action,
          user_choice: scene.user_choice,
          decision_actor: scene.decision_actor,
          affinity_impact: scene.affinity_delta,
          created_at: scene.created_at
        }
      end
    end
  end
end
