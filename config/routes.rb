# frozen_string_literal: true

OpenGeographies::Engine.routes.draw do
  # Unversioned (v0) routes, kept unchanged for consumers that have not yet
  # moved to v1.
  get ':project/places', to: 'places#index'
  get ':project/places/:slug', to: 'places#show'
  get ':project/tours/:slug', to: 'tours#show'

  namespace :v1 do
    get ':project/places', to: 'places#index'
    get ':project/places/:slug', to: 'places#show'
    get ':project/map_layers', to: 'map_layers#index'
    get ':project/map_layers/:slug', to: 'map_layers#show'
    get ':project/tours/:slug', to: 'tours#show'
  end
end
