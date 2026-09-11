# frozen_string_literal: true

require 'rails_helper'

RSpec.describe('CoreDataConnector::OpenGeographies::Places', type: :request) do
  describe 'GET /open_geographies/some_project/places' do
    it 'returns successful response with all places for single project' do
      project = CoreDataConnector::Project.last
      project_slug = project.name.parameterize
      get "/open_geographies/#{project_slug}/places"
      project_model = CoreDataConnector::Place.find(response_json.first[:id]).project_model
      expect(response).to(have_http_status(:ok))
      expect(response_json.map { |p| p[:project] }).to(all(eql(project_slug)))
      expect(response_json.count).to(eq(CoreDataConnector::OpenGeographies::Place.where(project_model:).count))
      expect(response_json.count).to(be < CoreDataConnector::OpenGeographies::Place.count)
    end
  end

  describe 'GET /open_geographies/some_project/places/some_place' do
    it 'returns 200 and a specific place' do
      place = CoreDataConnector::Place.first
      get "/open_geographies/#{place.project.name.parameterize}/places/#{place.name.parameterize}"
      expect(response).to(have_http_status(:ok))
      expect(response_json[:name]).to(eq(place.name))
    end

    it 'returns 404 when not found' do
      get '/open_geographies/some-project/places/some-place'
      expect(response).to(have_http_status(:not_found))
    end
  end
end
