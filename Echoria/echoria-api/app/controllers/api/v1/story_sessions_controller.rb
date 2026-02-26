module Api
  module V1
    class StorySessionsController < ApplicationController
      include DailyUsageLimitable

      before_action :authenticate_user!
      before_action :set_story_session, only: %i[show choose generate_scene pause resume story_log]
      before_action :set_echo, only: [:create]

      # POST /api/v1/story_sessions
      # Starts a new story session for an Echo in a given chapter.
      def create
        chapter = params.require(:chapter)
        first_beacon = StoryBeacon.in_chapter(chapter).ordered.first

        unless first_beacon
          return render json: { error: I18n.t("echoria.errors.chapter_not_found") }, status: :not_found
        end

        # Prevent duplicate active sessions in the same chapter
        existing = @echo.story_sessions.active_sessions.by_chapter(chapter).first
        if existing
          return render json: {
            error: I18n.t("echoria.errors.active_session_exists"),
            session_id: existing.id
          }, status: :conflict
        end

        # Also check for paused sessions — offer to resume
        paused = @echo.story_sessions.where(status: :paused).by_chapter(chapter).first
        if paused
          return render json: {
            error: I18n.t("echoria.errors.paused_session_exists"),
            session_id: paused.id,
            paused: true
          }, status: :conflict
        end

        @session = @echo.story_sessions.build(
          chapter: chapter,
          current_beacon_id: first_beacon.id,
          scene_count: 0,
          status: :active
        )

        begin
          if @session.save
            # Create the first beacon scene automatically
            navigator = BeaconNavigatorService.new(@session)
            navigator.create_beacon_scene!

            render json: session_detail_response(@session.reload), status: :created
          else
            render json: { errors: @session.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotUnique
          # Race condition: another request created a session between our check and INSERT.
          # The partial unique index (active/paused) caught the duplicate — return the winner.
          existing = @echo.story_sessions
                         .where(status: %i[active paused])
                         .by_chapter(chapter)
                         .first

          render json: {
            error: I18n.t("echoria.errors.active_session_exists"),
            session_id: existing&.id
          }, status: :conflict
        end
      end

      # GET /api/v1/story_sessions/:id
      def show
        render json: session_detail_response(@session)
      end

      # POST /api/v1/story_sessions/:id/choose
      # Player makes a choice at the current beacon.
      def choose
        return unless check_daily_usage!(:scene)

        choice_index = params.require(:choice_index).to_i
        navigator = BeaconNavigatorService.new(@session)

        # Validate choice
        unless navigator.valid_choice?(choice_index)
          return render json: { error: I18n.t("echoria.errors.invalid_choice") }, status: :bad_request
        end

        selected_choice = navigator.choice_at(choice_index)
        affinity_calc = AffinityCalculatorService.new(@session)

        # Generate AI scene based on the choice
        result = StoryGeneratorService.new(@session, selected_choice).call

        # Validate generated content against lore constraints
        lore_check = LoreConstraintLayer.validate!(result[:narrative], @session)
        narrative_text = lore_check[:valid] ? result[:narrative] : lore_check[:sanitized]

        # Wrap DB mutations in a transaction for atomicity
        scene = nil
        next_beacon = nil
        ActiveRecord::Base.transaction do
          # Create the scene with dialogue and inner monologues
          scene = @session.story_scenes.create!(
            scene_order: @session.scene_count + 1,
            scene_type: result[:scene_type],
            beacon_id: @session.current_beacon_id,
            narrative: narrative_text,
            echo_action: result[:echo_inner] || result[:echo_action],
            user_choice: selected_choice["choice_text"] || selected_choice["text"],
            decision_actor: :player,
            affinity_delta: result[:affinity_delta],
            generation_metadata: {
              dialogue: result[:dialogue] || [],
              tiara_inner: result[:tiara_inner]
            }.compact
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
        end

        increment_daily_usage!

        # Collect newly evolved skills for response
        evolved = (affinity_calc.newly_evolved_skills || []).map do |s|
          { skill_id: s.skill_id, title: s.title, layer: s.layer }
        end

        # Check for chapter end
        is_chapter_end = navigator.chapter_end?

        # Auto-complete session when chapter ends
        if is_chapter_end
          @session.update!(status: :completed)
        end

        @session.reload

        response = {
          scene: scene_response(scene),
          session: session_summary(@session),
          next_choices: is_chapter_end ? [] : (next_beacon&.choices || @session.current_beacon&.choices || []),
          chapter_end: is_chapter_end,
          beacon_progress: navigator.beacon_progress,
          evolved_skills: evolved,
          chapter: @session.chapter
        }

        if is_chapter_end
          response[:crystallization_available] = affinity_calc.crystallization_ready?
          response[:next_chapter] = next_chapter_for(@session.chapter)
        end

        render json: response, status: :ok
      end

      # POST /api/v1/story_sessions/:id/generate_scene
      # Generates an AI scene without explicit player choice (auto-progression).
      def generate_scene
        return unless check_daily_usage!(:scene)

        result = StoryGeneratorService.new(@session, nil).call

        # Lore validation
        lore_check = LoreConstraintLayer.validate!(result[:narrative], @session)
        narrative_text = lore_check[:valid] ? result[:narrative] : lore_check[:sanitized]

        scene = @session.story_scenes.create!(
          scene_order: @session.scene_count + 1,
          scene_type: result[:scene_type],
          beacon_id: @session.current_beacon_id,
          narrative: narrative_text,
          echo_action: result[:echo_inner] || result[:echo_action],
          decision_actor: :system,
          affinity_delta: result[:affinity_delta],
          generation_metadata: {
            dialogue: result[:dialogue] || [],
            tiara_inner: result[:tiara_inner]
          }.compact
        )

        @session.update!(scene_count: @session.scene_count + 1)

        # Apply generated affinity delta
        AffinityCalculatorService.new(@session).apply_generated_delta(result)

        increment_daily_usage!

        @session.reload
        render json: {
          scene: scene_response(scene),
          session: session_summary(@session)
        }, status: :created
      end

      # POST /api/v1/story_sessions/:id/pause
      # Saves and pauses the current story session.
      def pause
        unless @session.active?
          return render json: { error: I18n.t("echoria.errors.session_not_active") }, status: :unprocessable_entity
        end

        @session.update!(status: :paused)
        render json: {
          message: "物語を保存しました",
          session: session_summary(@session)
        }, status: :ok
      end

      # POST /api/v1/story_sessions/:id/resume
      # Resumes a paused story session.
      def resume
        unless @session.paused?
          return render json: { error: I18n.t("echoria.errors.session_not_paused") }, status: :unprocessable_entity
        end

        @session.update!(status: :active)
        render json: session_detail_response(@session), status: :ok
      end

      # GET /api/v1/story_sessions/:id/story_log
      # Returns all scenes in order for novel-reading view.
      def story_log
        scenes = @session.story_scenes.ordered.includes(:beacon)

        render json: {
          session: {
            id: @session.id,
            chapter: @session.chapter,
            status: @session.status,
            scene_count: @session.scene_count,
            affinity: @session.affinity,
            created_at: @session.created_at,
            updated_at: @session.updated_at,
            echo_name: @session.echo.name
          },
          scenes: scenes.map { |s| story_log_scene(s) }
        }, status: :ok
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

      CHAPTER_ORDER = %w[prologue chapter_1 chapter_2 chapter_3].freeze

      def next_chapter_for(current_chapter)
        idx = CHAPTER_ORDER.index(current_chapter)
        return nil unless idx
        CHAPTER_ORDER[idx + 1]
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
        metadata = scene.generation_metadata || {}
        {
          id: scene.id,
          order: scene.scene_order,
          type: scene.scene_type,
          narrative: scene.narrative,
          dialogue: metadata["dialogue"] || [],
          echo_inner: scene.echo_action,
          tiara_inner: metadata["tiara_inner"],
          user_choice: scene.user_choice,
          decision_actor: scene.decision_actor,
          affinity_delta: scene.affinity_delta || {},
          created_at: scene.created_at
        }
      end

      def story_log_scene(scene)
        metadata = scene.generation_metadata || {}
        result = {
          id: scene.id,
          order: scene.scene_order,
          type: scene.scene_type,
          narrative: scene.narrative,
          dialogue: metadata["dialogue"] || [],
          echo_inner: scene.echo_action,
          tiara_inner: metadata["tiara_inner"],
          user_choice: scene.user_choice,
          decision_actor: scene.decision_actor,
          affinity_delta: scene.affinity_delta || {},
          created_at: scene.created_at
        }

        # Include beacon title for section headers
        if scene.beacon.present?
          result[:beacon_title] = scene.beacon.title
          result[:location] = scene.beacon.metadata&.dig("location")
        end

        result
      end
    end
  end
end
