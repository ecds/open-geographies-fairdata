# frozen_string_literal: true

Rails.application.routes.draw do
  mount OpenGeographies::Engine, at: '/open_geographies'
end
