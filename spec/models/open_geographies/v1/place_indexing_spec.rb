# frozen_string_literal: true

require 'rails_helper'

# Uses a real Elasticsearch index and not a mock, to catch mismatches between
# the document and the mapping. A plain Ruby assertion on search_data's hash
# cannot detect that the mapping rejects a shape; only an index write can.
RSpec.describe('V1 Place Elasticsearch indexing') do
  after do
    index = OpenGeographies::V1::Place.searchkick_index
    index.delete if index.exists?
  end

  it 'indexes a real Place - with geometry, a promoted taxonomy relationship, and a UDF - without a mapping conflict' do
    project = create(:project)
    place_model = create(:place_model, project:)
    place = create(:place, project_model: place_model, name: 'Evergreen Church')
    create(:place_geometry, place:)

    types_model = create(:taxonomy_model, project:)
    rel = create(:project_model_relationship, primary_model: place_model, related_model: types_model, name: 'Types', multiple: true)
    church = create(:taxonomy, project_model: types_model, name: 'Church')
    create(:relationship, project_model_relationship: rel, primary_record: place, related_record: church)

    udf = create(:user_defined_field, defineable: place_model, column_name: 'Description', data_type: 'RichText')
    place.update!(user_defined: { udf.uuid => 'A historic church.' })

    OpenGeographies::V1::Place.reindex(refresh: true)

    # spec/seeds.rb seeds 15 unrelated Place records into the same test DB on
    # every suite start, and .reindex picks all of them up - search by slug,
    # not .first, so this test isn't at the mercy of ES's result ordering.
    result = OpenGeographies::V1::Place
      .search('*', where: { model_type: 'place', slug: 'evergreen-church' }, load: false)
      .first

    expect(result[:name]).to(eq('Evergreen Church'))
    expect(result[:types]).to(eq(['Church']))
    expect(result[:description]).to(eq('A historic church.'))
    expect(result[:geo][:point]).to(be_present)
  end

  it 'indexes a polygon as geo.shape and finds it with a geo_shape query' do
    project = create(:project)
    place_model = create(:place_model, project:)
    place = create(:place, project_model: place_model, name: 'Putnam County')
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    square = factory.polygon(factory.linear_ring([
      factory.point(-83.6, 32.4), factory.point(-83.4, 32.4), factory.point(-83.4, 32.6),
      factory.point(-83.6, 32.6), factory.point(-83.6, 32.4),
    ]))
    create(:place_geometry, place:, geometry: square)

    OpenGeographies::V1::Place.reindex(refresh: true)

    inside = { geo_shape: { 'geo.shape' => { shape: { type: 'point', coordinates: [-83.5, 32.5] }, relation: 'intersects' } } }
    results = OpenGeographies::V1::Place.search('*', body: { query: inside }, load: false).to_a

    expect(results.map { |r| r[:name] }).to(include('Putnam County'))
  end
end
