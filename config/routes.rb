# frozen_string_literal: true

OpenGeographies::Engine.routes.draw do
  # Unversioned (v0). Existing consumers keep hitting these unchanged while
  # they migrate to v1 on their own schedule - nothing here should change
  # once v1 exists alongside it.
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
