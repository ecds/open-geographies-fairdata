# frozen_string_literal: true

require 'rails_helper'

RSpec.describe('CoreDataConnector::OpenGeographies::V1::Place geojson export') do
  let(:project) { create(:project) }
  let(:place_model) { create(:place_model, project:) }
  let(:factory) { RGeo::Geographic.spherical_factory(srid: 4326) }

  describe '#geojson_features' do
    it 'returns no features for a place with no geometry' do
      place = create(:place, project_model: place_model, name: 'No Geometry')
      v1_place = CoreDataConnector::OpenGeographies::V1::Place.find(place.id)

      expect(v1_place.geojson_features).to(eq([]))
    end

    it 'returns one real (not centroid-reduced) Feature for a Point, with OG-schema-shaped properties' do
      place = create(:place, project_model: place_model, name: 'Evergreen Church')
      create(:place_geometry, place:, geometry: factory.point(-81.5, 34.5))
      v1_place = CoreDataConnector::OpenGeographies::V1::Place.find(place.id)

      features = v1_place.geojson_features
      expect(features.size).to(eq(1))
      expect(features.first[:type]).to(eq('Feature'))
      expect(features.first[:geometry]).to(eq({ 'type' => 'Point', 'coordinates' => [-81.5, 34.5] }))

      properties = features.first[:properties]
      expect(properties).to(eq({
        uuid: place.uuid,
        slug: 'evergreen-church',
        name: 'Evergreen Church',
        model_type: 'place',
        project: project.name.parameterize,
        types: [],
      }))
    end

    # Regression coverage for the actual reason this exists: #extras (used
    # for the ES index) only ever computes a single centroid point via SQL -
    # correct for a search summary, but it throws away the real shape. A
    # GeometryCollection (Georgia Coast has 1,766 of them - e.g. a barrier
    # island's separate islets) must explode into one Feature per member
    # geometry here, not collapse to one point.
    it 'explodes a GeometryCollection into one Feature per member geometry' do
      place = create(:place, project_model: place_model, name: 'Multi-Part Feature')
      collection = factory.collection([factory.point(-81.0, 34.0), factory.point(-82.0, 35.0)])
      create(:place_geometry, place:, geometry: collection)
      v1_place = CoreDataConnector::OpenGeographies::V1::Place.find(place.id)

      features = v1_place.geojson_features
      expect(features.size).to(eq(2))
      expect(features.map { |f| f[:geometry] }).to(eq([
        { 'type' => 'Point', 'coordinates' => [-81.0, 34.0] },
        { 'type' => 'Point', 'coordinates' => [-82.0, 35.0] },
      ]))
      # Every exploded Feature carries the same record-level properties -
      # they're independent shapes, not independent records.
      expect(features.map { |f| f[:properties][:uuid] }).to(eq([place.uuid, place.uuid]))
    end

    it 'includes promoted types as a bare array, matching how #related promotes them everywhere else' do
      types_model = create(:taxonomy_model, project:)
      rel = create(:project_model_relationship, primary_model: place_model, related_model: types_model, name: 'Types', multiple: true)
      church_type = create(:taxonomy, project_model: types_model, name: 'Church')
      place = create(:place, project_model: place_model, name: 'Typed Church')
      create(:place_geometry, place:, geometry: factory.point(-81.0, 34.0))
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: church_type)
      v1_place = CoreDataConnector::OpenGeographies::V1::Place.find(place.id)

      expect(v1_place.geojson_features.first[:properties][:types]).to(eq(['Church']))
    end
  end

  describe '.each_geojson_feature' do
    it 'streams a Feature per place in the given project_model, scoped away from other project models' do
      other_model = create(:place_model, project:)
      included = create(:place, project_model: place_model, name: 'Included')
      create(:place_geometry, place: included, geometry: factory.point(-81.0, 34.0))
      excluded = create(:place, project_model: other_model, name: 'Excluded')
      create(:place_geometry, place: excluded, geometry: factory.point(-82.0, 35.0))

      features = CoreDataConnector::OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
      expect(features.size).to(eq(1))
      expect(features.first[:properties][:name]).to(eq('Included'))
    end

    it 'returns an Enumerator when no block is given' do
      expect(CoreDataConnector::OpenGeographies::V1::Place.each_geojson_feature(place_model)).to(be_an(Enumerator))
    end
  end
end
