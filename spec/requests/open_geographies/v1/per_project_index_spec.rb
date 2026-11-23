# frozen_string_literal: true

require 'rails_helper'

# The v1 API under OG_INDEX_LAYOUT=per_project, against real Elasticsearch.
RSpec.describe('OpenGeographies::V1 with per-project indexes', type: :request) do
  let(:indexes) { OpenGeographies::V1::Indexes }
  let(:project) { create(:project) }
  let(:place_model) { create(:place_model, project:) }
  let(:project_slug) { project.name.parameterize }

  around do |example|
    previous_layout = ENV.fetch('OG_INDEX_LAYOUT', nil)
    previous_adapter = ActiveJob::Base.queue_adapter
    ENV['OG_INDEX_LAYOUT'] = 'per_project'
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    previous_layout.nil? ? ENV.delete('OG_INDEX_LAYOUT') : ENV['OG_INDEX_LAYOUT'] = previous_layout
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  after do
    client = Searchkick.client
    client.indices.get(index: 'open_geographies_v1_project_*').each_key { |name| client.indices.delete(index: name) }
    shared = OpenGeographies::V1::Place.searchkick_index
    shared.delete if shared.exists?
  end

  it "lists and shows places from the project's own index" do
    create(:place, project_model: place_model, name: 'Evergreen Church')
    indexes.rebuild(project.id)

    get "/open_geographies/v1/#{project_slug}/places"
    expect(response).to(have_http_status(:ok))
    expect(response_json[:results].map { |r| r[:name] }).to(eq(['Evergreen Church']))

    get "/open_geographies/v1/#{project_slug}/places/evergreen-church"
    expect(response).to(have_http_status(:ok))
    expect(response_json[:name]).to(eq('Evergreen Church'))
  end

  it 'does not read the shared index' do
    create(:place, project_model: place_model, name: 'Evergreen Church')
    indexes.rebuild(project.id)

    # Written to the shared index only, with the per-record callbacks off.
    shared_only = OpenGeographies::V1::Reindexable.disable { create(:place, project_model: place_model, name: 'Shared Only') }
    shared = OpenGeographies::V1::Place.searchkick_index
    shared.create(shared.index_options)
    shared.store(OpenGeographies::V1::Place.find(shared_only.id))
    shared.refresh
    indexes.project_index(project.id).refresh
    expect(shared.total_docs).to(eq(1))

    get "/open_geographies/v1/#{project_slug}/places"

    expect(response_json[:results].map { |r| r[:name] }).to(eq(['Evergreen Church']))
  end

  it "returns an empty page, and not found for a record, while the project's index is not built" do
    create(:place, project_model: place_model, name: 'Evergreen Church')

    get "/open_geographies/v1/#{project_slug}/places"
    expect(response).to(have_http_status(:ok))
    expect(response_json[:results]).to(eq([]))
    expect(response_json[:meta][:total_count]).to(eq(0))

    get "/open_geographies/v1/#{project_slug}/places/evergreen-church"
    expect(response).to(have_http_status(:not_found))
  end

  it 'returns not found for an unknown project' do
    get '/open_geographies/v1/no-such-project/places'

    expect(response).to(have_http_status(:not_found))
  end
end
