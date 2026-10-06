# frozen_string_literal: true

require 'rails_helper'

RSpec.describe('OpenGeographies::V1::Place geojson export') do
  let(:project) { create(:project) }
  let(:place_model) { create(:place_model, project:) }
  let(:factory) { RGeo::Geographic.spherical_factory(srid: 4326) }

  describe '#geojson_features' do
    it 'returns no features for a place with no geometry' do
      place = create(:place, project_model: place_model, name: 'No Geometry')
      v1_place = OpenGeographies::V1::Place.find(place.id)

      expect(v1_place.geojson_features).to(eq([]))
    end

    it 'returns one real (not centroid-reduced) Feature for a Point, with OG-schema-shaped properties' do
      place = create(:place, project_model: place_model, name: 'Evergreen Church')
      create(:place_geometry, place:, geometry: factory.point(-81.5, 34.5))
      v1_place = OpenGeographies::V1::Place.find(place.id)

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
        model_id: place_model.id.to_s,
        model_name: place_model.name,
        project: project.name.parameterize,
        types: [],
        admin_level: nil,
      }))
    end

    it 'reads admin_level from the generic "Admin Level" UDF, same mechanism as any other UDF' do
      udf = create(:user_defined_field, defineable: place_model, column_name: 'Admin Level', data_type: 'Select')
      place = create(:place, project_model: place_model, name: 'Putnam County', user_defined: { udf.uuid => 'ADM2' })
      create(:place_geometry, place:, geometry: factory.point(-83.0, 32.5))
      v1_place = OpenGeographies::V1::Place.find(place.id)

      expect(v1_place.geojson_features.first[:properties][:admin_level]).to(eq('ADM2'))
    end

    # #extras (used for the search index) only computes a centroid, which is
    # enough for a search summary but discards the real shape. A
    # GeometryCollection must be split into one Feature per member geometry and
    # not collapsed to a point.
    it 'explodes a GeometryCollection into one Feature per member geometry' do
      place = create(:place, project_model: place_model, name: 'Multi-Part Feature')
      collection = factory.collection([factory.point(-81.0, 34.0), factory.point(-82.0, 35.0)])
      create(:place_geometry, place:, geometry: collection)
      v1_place = OpenGeographies::V1::Place.find(place.id)

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
      v1_place = OpenGeographies::V1::Place.find(place.id)

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

      features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
      expect(features.size).to(eq(1))
      expect(features.first[:properties][:name]).to(eq('Included'))
    end

    it 'returns an Enumerator when no block is given' do
      expect(OpenGeographies::V1::Place.each_geojson_feature(place_model)).to(be_an(Enumerator))
    end

    # The output is typically published publicly and, unlike the search index,
    # nothing else filters out unpublished records, so this query must.
    it 'excludes an unpublished place, matching should_index?' do
      published = create(:place, project_model: place_model, name: 'Published Church')
      create(:place_geometry, place: published, geometry: factory.point(-81.0, 34.0))
      unpublished = create(:place, project_model: place_model, name: 'Draft Church')
      create(:place_geometry, place: unpublished, geometry: factory.point(-82.0, 35.0))
      unpublished.update!(published: false)

      features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
      expect(features.map { |f| f[:properties][:name] }).to(eq(['Published Church']))
    end

    # A place's Contained In target (such as the county a place belongs to) is
    # usually not a member of the project_model being exported, and is often in
    # another project, so it would not be exported unless it is pulled in.
    describe "a place's Contained In target" do
      def build_contained_in_setup(area_geometry)
        county_model = create(:place_model, project:)
        county = create(:place, project_model: county_model, name: 'Putnam County')
        create(:place_geometry, place: county, geometry: area_geometry)
        rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
        church = create(:place, project_model: place_model, name: 'Friendship Baptist')
        create(:place_geometry, place: church, geometry: factory.point(-83.0, 32.5))
        create(:relationship, project_model_relationship: rel, primary_record: church, related_record: county)
        church
      end

      it "includes the target's own polygon feature, marked contained_in: true" do
        polygon = factory.polygon(factory.linear_ring([
          factory.point(-83.6, 32.4),
          factory.point(-83.4, 32.4),
          factory.point(-83.4, 32.6),
          factory.point(-83.6, 32.6),
          factory.point(-83.6, 32.4),
        ]))
        build_contained_in_setup(polygon)

        features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
        admin_features = features.select { |f| f[:properties][:contained_in] }

        expect(admin_features.size).to(eq(1))
        expect(admin_features.first[:properties][:name]).to(eq('Putnam County'))
        expect(admin_features.first[:geometry]['type']).to(eq('Polygon'))
      end

      # Admin-area features are pinned to tippecanoe.minzoom 0 so that
      # --drop-densest-as-needed, which thins points across the whole tile, cannot
      # drop them at low zooms. Ordinary places are not pinned and are still thinned.
      it 'pins every admin-area feature to tippecanoe.minzoom: 0, exempting it from density-based tile thinning' do
        polygon = factory.polygon(factory.linear_ring([
          factory.point(-83.6, 32.4),
          factory.point(-83.4, 32.4),
          factory.point(-83.4, 32.6),
          factory.point(-83.6, 32.6),
          factory.point(-83.6, 32.4),
        ]))
        build_contained_in_setup(polygon)

        features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
        church_feature = features.find { |f| f[:properties][:name] == 'Friendship Baptist' }
        county_feature = features.find { |f| f[:properties][:name] == 'Putnam County' }

        expect(county_feature[:tippecanoe]).to(eq({ minzoom: 0 }))
        expect(church_feature).not_to(have_key(:tippecanoe))
      end

      # model_id and model_name say which project_model each feature came from.
      # A Contained In chain can pass through a project_model other than the one
      # being exported, so `contained_in` alone is not enough.
      it "tags the church with --place-model's own project_model, and the county with its own, different one" do
        polygon = factory.polygon(factory.linear_ring([
          factory.point(-83.6, 32.4),
          factory.point(-83.4, 32.4),
          factory.point(-83.4, 32.6),
          factory.point(-83.6, 32.6),
          factory.point(-83.6, 32.4),
        ]))
        build_contained_in_setup(polygon)

        features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
        church_feature = features.find { |f| f[:properties][:name] == 'Friendship Baptist' }
        county_feature = features.find { |f| f[:properties][:name] == 'Putnam County' }

        expect(church_feature[:properties][:model_id]).to(eq(place_model.id.to_s))
        expect(church_feature[:properties][:model_name]).to(eq(place_model.name))
        expect(county_feature[:properties][:model_id]).not_to(eq(place_model.id.to_s))
      end

      it "includes a county's leftover Point alongside its boundary - a client's label layer needs somewhere to anchor text" do
        polygon_ring = factory.linear_ring([
          factory.point(-83.6, 32.4),
          factory.point(-83.4, 32.4),
          factory.point(-83.4, 32.6),
          factory.point(-83.6, 32.6),
          factory.point(-83.6, 32.4),
        ])
        collection = factory.collection([factory.point(-83.5, 32.5), factory.polygon(polygon_ring)])
        build_contained_in_setup(collection)

        features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
        admin_features = features.select { |f| f[:properties][:contained_in] }

        expect(admin_features.map { |f| f[:geometry]['type'] }).to(contain_exactly('Point', 'Polygon'))
        expect(admin_features.map { |f| f[:properties][:name] }).to(eq(['Putnam County', 'Putnam County']))
      end

      it 'is not duplicated when multiple places in the export share the same containing area' do
        county_model = create(:place_model, project:)
        county = create(:place, project_model: county_model, name: 'Putnam County')
        create(:place_geometry, place: county, geometry: factory.polygon(factory.linear_ring([
          factory.point(-83.6, 32.4),
          factory.point(-83.4, 32.4),
          factory.point(-83.4, 32.6),
          factory.point(-83.6, 32.6),
          factory.point(-83.6, 32.4),
        ])))
        rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')

        ['Friendship Baptist', 'Salem Methodist'].each do |name|
          church = create(:place, project_model: place_model, name:)
          create(:place_geometry, place: church, geometry: factory.point(-83.0, 32.5))
          create(:relationship, project_model_relationship: rel, primary_record: church, related_record: county)
        end

        features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
        admin_features = features.select { |f| f[:properties][:contained_in] }

        expect(admin_features.size).to(eq(1))
      end

      it "excludes the target when it's unpublished, same reason as the place itself" do
        county_model = create(:place_model, project:)
        county = create(:place, project_model: county_model, name: 'Putnam County')
        create(:place_geometry, place: county, geometry: factory.polygon(factory.linear_ring([
          factory.point(-83.6, 32.4),
          factory.point(-83.4, 32.4),
          factory.point(-83.4, 32.6),
          factory.point(-83.6, 32.6),
          factory.point(-83.6, 32.4),
        ])))
        county.update!(published: false)
        rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
        church = create(:place, project_model: place_model, name: 'Friendship Baptist')
        create(:place_geometry, place: church, geometry: factory.point(-83.0, 32.5))
        create(:relationship, project_model_relationship: rel, primary_record: church, related_record: county)

        features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a

        expect(features.none? { |f| f[:properties][:contained_in] }).to(be(true))
      end

      it 'emits nothing extra for a place with no Contained In relationship' do
        place = create(:place, project_model: place_model, name: 'Unlinked Church')
        create(:place_geometry, place:, geometry: factory.point(-81.0, 34.0))

        features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a

        expect(features.none? { |f| f[:properties][:contained_in] }).to(be(true))
      end

      def square_polygon
        factory.polygon(factory.linear_ring([
          factory.point(-83.6, 32.4),
          factory.point(-83.4, 32.4),
          factory.point(-83.4, 32.6),
          factory.point(-83.6, 32.6),
          factory.point(-83.6, 32.4),
        ]))
      end

      describe 'walking the whole chain, not just the immediate target' do
        it "includes the county's own Contained In target too (the state), not just the county" do
          state_model = create(:place_model, project:)
          state = create(:place, project_model: state_model, name: 'Georgia')
          create(:place_geometry, place: state, geometry: square_polygon)

          county_model = create(:place_model, project:)
          county = create(:place, project_model: county_model, name: 'Putnam County')
          create(:place_geometry, place: county, geometry: square_polygon)
          county_rel = create(:project_model_relationship, primary_model: county_model, related_model: state_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
          create(:relationship, project_model_relationship: county_rel, primary_record: county, related_record: state)

          church_rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
          church = create(:place, project_model: place_model, name: 'Friendship Baptist')
          create(:place_geometry, place: church, geometry: factory.point(-83.0, 32.5))
          create(:relationship, project_model_relationship: church_rel, primary_record: church, related_record: county)

          features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
          admin_names = features.select { |f| f[:properties][:contained_in] }.map { |f| f[:properties][:name] }

          expect(admin_names).to(contain_exactly('Putnam County', 'Georgia'))
        end

        it 'emits the shared state exactly once across many places in different counties, not once per county' do
          state_model = create(:place_model, project:)
          state = create(:place, project_model: state_model, name: 'Georgia')
          create(:place_geometry, place: state, geometry: square_polygon)

          county_model = create(:place_model, project:)
          county_rel = create(:project_model_relationship, primary_model: county_model, related_model: state_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
          church_rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')

          ['Putnam County', 'Sumter County'].each do |county_name|
            county = create(:place, project_model: county_model, name: county_name)
            create(:place_geometry, place: county, geometry: square_polygon)
            create(:relationship, project_model_relationship: county_rel, primary_record: county, related_record: state)

            church = create(:place, project_model: place_model, name: "Church in #{county_name}")
            create(:place_geometry, place: church, geometry: factory.point(-83.0, 32.5))
            create(:relationship, project_model_relationship: church_rel, primary_record: church, related_record: county)
          end

          features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
          admin_features = features.select { |f| f[:properties][:contained_in] }

          expect(admin_features.map { |f| f[:properties][:name] }).to(contain_exactly('Putnam County', 'Sumter County', 'Georgia'))
        end

        it "keeps walking past an unpublished county to reach the state above it, even though the county itself isn't emitted" do
          state_model = create(:place_model, project:)
          state = create(:place, project_model: state_model, name: 'Georgia')
          create(:place_geometry, place: state, geometry: square_polygon)

          county_model = create(:place_model, project:)
          county = create(:place, project_model: county_model, name: 'Putnam County')
          create(:place_geometry, place: county, geometry: square_polygon)
          county.update!(published: false)
          county_rel = create(:project_model_relationship, primary_model: county_model, related_model: state_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
          create(:relationship, project_model_relationship: county_rel, primary_record: county, related_record: state)

          church_rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
          church = create(:place, project_model: place_model, name: 'Friendship Baptist')
          create(:place_geometry, place: church, geometry: factory.point(-83.0, 32.5))
          create(:relationship, project_model_relationship: church_rel, primary_record: church, related_record: county)

          features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a
          admin_names = features.select { |f| f[:properties][:contained_in] }.map { |f| f[:properties][:name] }

          expect(admin_names).to(eq(['Georgia']))
        end

        it "doesn't hang on a malformed Contained In cycle" do
          county_model = create(:place_model, project:)
          county_a = create(:place, project_model: county_model, name: 'County A')
          create(:place_geometry, place: county_a, geometry: square_polygon)
          county_b = create(:place, project_model: county_model, name: 'County B')
          create(:place_geometry, place: county_b, geometry: square_polygon)

          rel = create(:project_model_relationship, primary_model: county_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
          create(:relationship, project_model_relationship: rel, primary_record: county_a, related_record: county_b)
          create(:relationship, project_model_relationship: rel, primary_record: county_b, related_record: county_a)

          church_rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
          church = create(:place, project_model: place_model, name: 'Friendship Baptist')
          create(:place_geometry, place: church, geometry: factory.point(-83.0, 32.5))
          create(:relationship, project_model_relationship: church_rel, primary_record: church, related_record: county_a)

          features = nil
          expect do
            Timeout.timeout(5) { features = OpenGeographies::V1::Place.each_geojson_feature(place_model).to_a }
          end.not_to(raise_error)

          admin_names = features.select { |f| f[:properties][:contained_in] }.map { |f| f[:properties][:name] }
          expect(admin_names).to(contain_exactly('County A', 'County B'))
        end
      end
    end
  end
end
