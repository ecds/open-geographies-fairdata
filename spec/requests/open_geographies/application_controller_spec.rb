# frozen_string_literal: true

require 'rails_helper'

RSpec.describe('OpenGeographies::ApplicationController Shared Behavior', type: :request) do
  before do
    stub_const('TestController', Class.new(OpenGeographies::ApplicationController))

    Rails.application.routes.draw do
      get    'test_controller',     to: 'test#index'
      get    'test_controller/:id', to: 'test#show'
      post   'test_controller',     to: 'test#create'
      patch  'test_controller/:id', to: 'test#update'
      delete 'test_controller/:id', to: 'test#destroy'
    end
  end

  after do
    Rails.application.reload_routes!
  end

  it 'returns 403 when method is index' do
    get '/test_controller'
    expect(response).to(have_http_status(:not_implemented))
  end

  it 'returns 403 when method is show' do
    get '/test_controller/1'
    expect(response).to(have_http_status(:not_implemented))
  end

  it 'returns 403 when method is create' do
    post '/test_controller'
    expect(response).to(have_http_status(:not_implemented))
  end

  it 'returns 403 when method is update' do
    patch '/test_controller/1'
    expect(response).to(have_http_status(:not_implemented))
  end

  it 'returns 403 when method is destroy' do
    delete '/test_controller/1'
    expect(response).to(have_http_status(:not_implemented))
  end
end
