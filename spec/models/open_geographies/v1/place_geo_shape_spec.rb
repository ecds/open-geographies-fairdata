# frozen_string_literal: true

require 'rails_helper'

# Checks the Ruby hash from #search_data, not a real index.
RSpec.describe('V1::Place geo.shape') do
  around do |example|
    OpenGeographies::V1::Reindexable.disable { example.run }
  end

  let(:project) { create(:project) }
  let(:place_model) { create(:place_model, project:) }
  let(:factory) { RGeo::Geographic.spherical_factory(srid: 4326) }

  def square(west, south, size)
    factory.polygon(factory.linear_ring([
      factory.point(west, south),
      factory.point(west + size, south),
      factory.point(west + size, south + size),
      factory.point(west, south + size),
      factory.point(west, south),
    ]))
  end

  def circle(vertices, radius)
    points = Array.new(vertices) do |i|
      angle = 2 * Math::PI * i / vertices
      factory.point(-83.0 + (radius * Math.cos(angle)), 32.5 + (radius * Math.sin(angle)))
    end
    factory.polygon(factory.linear_ring(points + [points.first]))
  end

  def search_data_for(geometry)
    place = create(:place, project_model: place_model, name: 'Shaped Place')
    create(:place_geometry, place:, geometry:)
    OpenGeographies::V1::Place.find(place.id).search_data
  end

  def vertex_count(shape)
    coordinates = shape['coordinates']
    coordinates = coordinates.flatten(shape['type'] == 'MultiPolygon' ? 2 : 1)
    coordinates.size
  end

  it 'indexes a polygon as geo.shape and keeps geo.point' do
    data = search_data_for(square(-83.6, 32.4, 0.2))

    expect(data[:geo][:shape]['type']).to(eq('Polygon'))
    expect(data[:geo][:point]).to(be_present)
  end

  it 'has no geo.shape for a point' do
    data = search_data_for(factory.point(-83.0, 32.5))

    expect(data[:geo]).not_to(have_key(:shape))
    expect(data[:geo][:point]).to(be_present)
  end

  it 'has no geo.shape for a line' do
    line = factory.line_string([factory.point(-83.0, 32.5), factory.point(-82.0, 33.0)])

    expect(search_data_for(line)[:geo]).not_to(have_key(:shape))
  end

  it 'keeps only the polygon of a GeometryCollection that also has a point' do
    collection = factory.collection([factory.point(-83.0, 32.5), square(-83.6, 32.4, 0.2)])
    shape = search_data_for(collection)[:geo][:shape]

    expect(shape['type']).to(eq('MultiPolygon'))
    expect(shape['coordinates'].size).to(eq(1))
  end

  it 'has no geo.shape or geo.point for a place without geometry' do
    place = create(:place, project_model: place_model, name: 'No Geometry')

    expect(OpenGeographies::V1::Place.find(place.id).search_data).not_to(have_key(:geo))
  end

  it 'simplifies a shape with more than SHAPE_MAX_POINTS vertices' do
    stub_const('OpenGeographies::V1::Place::SHAPE_MAX_POINTS', 200)
    shape = search_data_for(circle(5_000, 0.5))[:geo][:shape]

    expect(vertex_count(shape)).to(be <= 200)
  end

  it 'leaves a shape under SHAPE_MAX_POINTS unsimplified' do
    shape = search_data_for(circle(50, 0.5))[:geo][:shape]

    expect(vertex_count(shape)).to(eq(51))
  end

  it 'does not embed geo.shape in the summary of a related place' do
    county_model = create(:place_model, project:)
    county = create(:place, project_model: county_model, name: 'Putnam County')
    create(:place_geometry, place: county, geometry: square(-83.6, 32.4, 0.2))
    rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
    church = create(:place, project_model: place_model, name: 'Friendship Baptist')
    create(:place_geometry, place: church, geometry: factory.point(-83.0, 32.5))
    create(:relationship, project_model_relationship: rel, primary_record: church, related_record: county)

    data = OpenGeographies::V1::Place.find(church.id).search_data

    expect(data[:contained_in_place][:geo]).not_to(have_key(:shape))
  end
end
