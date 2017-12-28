Rails.application.routes.draw do

  resources :tasks
  get 'home/index'

  get '/' => 'home#index'
  get '/getting-started' => 'home#getting_started'
  get '/documentation' => 'home#documentation'

  resources :tasks, default: {format: :html} do
    post 'launch'
  end

  resources :runs
end
