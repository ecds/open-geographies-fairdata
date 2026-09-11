# frozen_string_literal: true

require 'rails_helper'

# Real Elasticsearch, not a mock - same rationale as places_spec.rb: this is
# testing the actual HTTP route's behavior end to end, not just the
# project_id resolution method in isolation.
#
# Enforcement lives once in V1::ApplicationController#project_id (shared by
# every v1 controller), so this only exercises it through one representative
# endpoint (Places) rather than duplicating the same check across Tours/
# MapLayers too.
RSpec.describe('V1 discoverable enforcement', type: :request) do
  after do
    index = CoreDataConnector::OpenGeographies::V1::Place.searchkick_index
    index.delete if index.exists?
  end

  it 'hides a non-discoverable project from both #show and #index, even with the correct slug' do
    project = create(:project, discoverable: false)
    place_model = create(:place_model, project:)
    place = create(:place, project_model: place_model, name: 'Hidden Church')
    project_slug = project.name.parameterize

    CoreDataConnector::OpenGeographies::V1::Place.reindex(refresh: true)

    get "/open_geographies/v1/#{project_slug}/places/#{place.name.parameterize}"
    expect(response).to(have_http_status(:not_found))

    get "/open_geographies/v1/#{project_slug}/places"
    expect(response).to(have_http_status(:ok))
    expect(response_json[:results]).to(eq([]))
  end

  it 'serves a discoverable project normally' do
    project = create(:project, discoverable: true)
    place_model = create(:place_model, project:)
    place = create(:place, project_model: place_model, name: 'Visible Church')
    project_slug = project.name.parameterize

    CoreDataConnector::OpenGeographies::V1::Place.reindex(refresh: true)

    get "/open_geographies/v1/#{project_slug}/places/#{place.name.parameterize}"
    expect(response).to(have_http_status(:ok))
    expect(response_json[:name]).to(eq('Visible Church'))
  end
end
