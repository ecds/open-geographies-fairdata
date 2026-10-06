# frozen_string_literal: true

require 'rails_helper'

# Uses a real Elasticsearch index and not a mock, as in places_spec.rb and
# place_indexing_spec.rb. The point of this endpoint is the shape and order of
# stops[], which a Ruby-only test of #related cannot fully check once the
# document has been through indexing and es_mapping.json.
RSpec.describe('OpenGeographies::V1::Tours', type: :request) do
  after do
    index = OpenGeographies::V1::Place.searchkick_index
    index.delete if index.exists?
  end

  it 'returns a tour with its stops in order, each carrying its own geo point' do
    project = create(:project)
    place_model = create(:place_model, project:)
    project_slug = project.name.parameterize

    first_stop = create(:place, project_model: place_model, name: 'First Stop')
    create(:place_geometry, place: first_stop)
    second_stop = create(:place, project_model: place_model, name: 'Second Stop')
    create(:place_geometry, place: second_stop)

    tours_model = create(:place_model, project:, model_class: 'CoreDataConnector::Instance')
    stops_rel = create(:project_model_relationship, primary_model: tours_model, related_model: place_model, name: 'Stops', multiple: true)
    tour = create(:instance, project_model: tours_model, name: 'Sample Tour')

    # Deliberately created out of order - the relationship's own `order`
    # column, not creation order, is what stops[] must sort/carry.
    create(:relationship, project_model_relationship: stops_rel, primary_record: tour, related_record: second_stop, order: 2)
    create(:relationship, project_model_relationship: stops_rel, primary_record: tour, related_record: first_stop, order: 1)

    OpenGeographies::V1::Instance.reindex(refresh: true)

    get "/open_geographies/v1/#{project_slug}/tours/#{tour.name.parameterize}"
    expect(response).to(have_http_status(:ok))
    expect(response_json[:name]).to(eq('Sample Tour'))
    expect(response_json[:model_type]).to(eq('tour'))

    # No client-side sort here on purpose - stops[] must already come back
    # in order (#related's `.order(:order)` query), not just carry an
    # `order` value a client is expected to re-sort by itself.
    stops = response_json[:stops]
    expect(stops.map { |s| s[:name] }).to(eq(['First Stop', 'Second Stop']))
    expect(stops.map { |s| s[:order] }).to(eq([1, 2]))
    expect(stops[0][:geo][:point]).to(be_present)

    get '/open_geographies/v1/some-project/tours/some-tour'
    expect(response).to(have_http_status(:not_found))
  end
end
