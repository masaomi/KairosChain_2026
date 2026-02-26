Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      # Health check
      get "health", to: "health#check"

      # Authentication
      scope :auth do
        post "signup", to: "auth#signup"
        post "login", to: "auth#login"
        post "google", to: "auth#google"
        post "forgot_password", to: "auth#forgot_password"
        post "reset_password", to: "auth#reset_password"
      end

      # Echoes
      resources :echoes, only: %i[index create show update destroy] do
        member do
          get "export_skills", to: "echoes#export_skills"
          get "chain_status", to: "echoes#chain_status"
        end
      end

      # Story Sessions
      resources :story_sessions, only: %i[create show] do
        member do
          post "choose", to: "story_sessions#choose"
          post "generate_scene", to: "story_sessions#generate_scene"
          post "pause", to: "story_sessions#pause"
          post "resume", to: "story_sessions#resume"
          get "story_log", to: "story_sessions#story_log"
        end
      end

      # Conversations and Messages
      resources :conversations, only: %i[index create show] do
        resources :messages, only: %i[create index]
      end
    end
  end

  match "*path", to: proc { [404, {}, ["Not Found"]] }, via: :all
end
