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
      end

      # Echoes
      resources :echoes, only: %i[index create show update destroy]

      # Story Sessions
      resources :story_sessions, only: %i[create show] do
        member do
          post "choose", to: "story_sessions#choose"
          post "generate_scene", to: "story_sessions#generate_scene"
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
