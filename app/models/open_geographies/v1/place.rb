# frozen_string_literal: true

require 'rgeo/geo_json'

module OpenGeographies
  module V1
    class Place < ::CoreDataConnector::Place
      include Searchable

      searchable_index 'open_geographies_v1'

      self.table_name = 'core_data_connector_places'

      class << self
        # Streams one GeoJSON Feature per geometry for every published place
        # in `project_model`, for building vector tiles in bulk. It reads the
        # database directly and does not go through the search index (see
        # #geojson_features). Records are loaded in batches. Yields each
        # Feature when a block is given, otherwise returns an Enumerator.
        #
        # Each exported place's whole Contained In chain is emitted too: its
        # county, that county's state, and so on up to a record with no
        # Contained In relationship. These records usually belong to another
        # project_model, often in another project, so they would not
        # otherwise be exported. Each one is emitted once, deduplicated across
        # the whole run, and tagged `contained_in: true` so a client can tell
        # it apart from the exported model's own places.
        #
        # The walk continues past an unpublished link without emitting it, so
        # a hidden county does not also hide the state above it. The visited
        # set also guards against cycles in malformed Contained In data.
        #
        # Only published records are exported, matching the search indexing
        # gate in Searchable#should_index?. This query does not go through
        # Searchkick, so the check has to happen here. Exported output is
        # usually served publicly, so an unpublished record must not reach it.
        def each_geojson_feature(project_model, &block)
          return enum_for(:each_geojson_feature, project_model) unless block_given?

          visited_area_ids = Set.new

          where(project_model:).published.find_each do |place|
            place.geojson_features.each(&block)

            area = place.contained_in_place
            while area && !visited_area_ids.include?(area.id)
              visited_area_ids << area.id
              emit_admin_area_feature(area, &block) if area.published
              area = area.contained_in_place
            end
          end
        end

        private

        # Emits every member geometry of an admin area, not just its
        # boundary. An area stored as a GeometryCollection can hold both a
        # marker Point and a boundary Polygon: the Polygon renders the area
        # and the Point gives a label layer a fixed anchor. Every member is
        # tagged `contained_in: true`; a client tells them apart by geometry
        # type, e.g. `["==", ["geometry-type"], "Point"]` for labels.
        #
        # `tippecanoe: { minzoom: 0 }` is a top-level Feature member that
        # tippecanoe reads and does not write to the tile as an attribute. A
        # feature with an explicit minzoom is exempt from density-based
        # dropping (--drop-densest-as-needed), which otherwise thins points
        # across the whole tile regardless of layer. Without it, admin area
        # points are dropped at low zooms and no map style can bring back a
        # feature that is not in the tile.
        def emit_admin_area_feature(area, &block)
          area.geojson_features.each do |feature|
            block.call(feature.merge(
              properties: feature[:properties].merge(contained_in: true),
              tippecanoe: { minzoom: 0 },
            ))
          end
        end
      end

      def extras
        return {} unless place_geometry&.geometry

        center = centroid
        return {} unless center

        lat = center['lat'].to_f
        lon = center['lon'].to_f

        {
          geo: { point: { lat:, lon: } },
          administrative_area: ::OpenGeographies::GeonamesHierarchy.lookup(place_id: id, lat:, lng: lon),
        }
      end

      # Adds the polygon shape to the top-level document only. Nested summaries
      # of related places have no geo.shape mapping, and embedding a boundary in
      # every record that points at it would make documents very large.
      def search_data
        data = super
        shape = geo_shape
        data[:geo] = (data[:geo] || {}).merge(shape:) if shape
        data
      end

      def slug
        base = super
        suffix = containing_area_slug
        suffix ? "#{base}-#{suffix}" : base
      end

      # Includes the unsuffixed slug alongside the suffixed one, so links built
      # before a containing area was resolved still match. See Searchable#slugs
      # for why `slugs` accepts more values than the single canonical `slug`.
      def slugs
        base_slugs = super
        suffix = containing_area_slug
        return base_slugs unless suffix

        (base_slugs + base_slugs.map { |candidate| "#{candidate}-#{suffix}" }).uniq
      end

      # Returns one GeoJSON Feature per underlying geometry. A
      # GeometryCollection (a record made of several separate shapes) is split
      # into one Feature per member, so each shape can be drawn and clicked on
      # its own. The real geometry is read from place_geometry; #extras only
      # computes a centroid, which is enough for search but not for drawing.
      def geojson_features
        return [] unless place_geometry&.geometry

        encoded = RGeo::GeoJSON.encode(place_geometry.geometry)
        geometries = encoded['type'] == 'GeometryCollection' ? encoded['geometries'] : [encoded]

        geometries.map do |geometry|
          { type: 'Feature', properties: geojson_properties, geometry: }
        end
      end

      # The place this one is contained in, found through the model's promoted
      # Contained In relationship. Public because #slug needs it before
      # #related runs, and #each_geojson_feature calls it on other places.
      def contained_in_place
        rel_name = PromotedRelationships.for(self).key(:contained_in_place)
        return unless rel_name

        rel = ::CoreDataConnector::ProjectModelRelationship.find_by(primary_model: project_model, name: rel_name)
        return unless rel

        relationship = ::CoreDataConnector::Relationship.find_by(project_model_relationship: rel, primary_record: self)
        relationship && self.class.find(relationship.related_record_id)
      end

      private

      # GeoNames feature codes ranked from most specific (0) to broadest.
      # Only ADM1, ADM2 and PCLI come back from the reverse geocoder today;
      # ranking the rest means finer levels are handled if they appear. Codes
      # not listed here get whatever default is passed to `.fetch`.
      # Largest number of vertices kept in the indexed geo_shape. A larger shape is
      # simplified with the next tolerance in SHAPE_SIMPLIFY_TOLERANCES (degrees)
      # until it fits, or the last tolerance has been tried.
      SHAPE_MAX_POINTS = 1_000
      SHAPE_SIMPLIFY_TOLERANCES = [0.0001, 0.0005, 0.002, 0.01, 0.05].freeze

      GEONAMES_LEVEL_SPECIFICITY = { 'ADM5' => 0, 'ADM4' => 1, 'ADM3' => 2, 'ADM2' => 3, 'ADM1' => 4, 'PCLI' => 5 }.freeze

      # The name of the area containing this place, parameterized, used as a
      # slug suffix to tell apart places that share a name. Memoized because
      # #slug, #slugs and #extras each need it for the same record.
      #
      # It uses the containing place's #name and not its #slug, so the suffix
      # does not pick up another suffix at every level of the hierarchy. When
      # the place has no Contained In relationship, it falls back to a GeoNames
      # reverse geocode of the place's centroid.
      #
      # Top-level admin areas (Admin Level ADM1 or broader) get no suffix.
      # They have no containing area, and reverse geocoding their centroid
      # would return an unrelated smaller unit that happens to overlap it.
      # Places without an Admin Level field are unaffected, because
      # #admin_level is nil for them.
      def containing_area_slug
        return if top_level_admin_area?

        @containing_area_slug ||= (contained_in_place&.name || geonames_area_name)&.parameterize
      end

      def top_level_admin_area?
        GEONAMES_LEVEL_SPECIFICITY.fetch(admin_level, -1) >= GEONAMES_LEVEL_SPECIFICITY.fetch('ADM1')
      end

      # This record's value for the "Admin Level" user-defined field (ADM1,
      # ADM2, PCLI, ...), or nil when its project_model has no such field.
      # The field is found by column name, so it works for any model that
      # defines it.
      #
      # The value is read directly and not through #user_defined_fields,
      # because that method calls #slugs, which reaches this method through
      # #containing_area_slug, and the calls would recurse without end.
      def admin_level
        ud = project_model.user_defined_fields.find { |field| field.column_name == 'Admin Level' }
        ud && user_defined[ud.uuid]
      end

      # The polygon part of this place's geometry as GeoJSON for the geo_shape
      # field, or nil when it has none. Points are covered by geo.point and lines
      # are left out. Shapes over SHAPE_MAX_POINTS vertices are simplified.
      def geo_shape
        return unless place_geometry&.geometry

        best = nil
        [nil, *SHAPE_SIMPLIFY_TOLERANCES].each do |tolerance|
          row = polygon_shape_row(tolerance)
          break unless row

          best = row
          break if row['points'].to_i <= SHAPE_MAX_POINTS
        end

        best && JSON.parse(best['geojson'])
      end

      def polygon_shape_row(tolerance)
        shape_sql = 'ST_CollectionExtract(geometry, 3)'
        shape_sql = "ST_SimplifyPreserveTopology(#{shape_sql}, #{tolerance.to_f})" if tolerance

        ::CoreDataConnector::PlaceGeometry.connection.select_one(
          ::CoreDataConnector::PlaceGeometry.sanitize_sql_array([
            "SELECT ST_NPoints(shape) AS points, ST_AsGeoJSON(shape, 6) AS geojson " \
              "FROM (SELECT #{shape_sql} AS shape FROM core_data_connector_place_geometries WHERE id = ?) shapes " \
              "WHERE NOT ST_IsEmpty(shape)",
            place_geometry.id,
          ]),
        )
      end

      def geonames_area_name
        return unless place_geometry&.geometry

        center = centroid
        return unless center

        hierarchy = ::OpenGeographies::GeonamesHierarchy.lookup(
          place_id: id, lat: center['lat'].to_f, lng: center['lon'].to_f,
        )
        hierarchy.min_by { |entry| GEONAMES_LEVEL_SPECIFICITY.fetch(entry[:level], 99) }&.dig(:name)
      end

      # A flat subset of #base_search_data, kept small because these become
      # vector tile attributes.
      #
      # It does not use #search_data, which calls #extras and can make a live
      # GeoNames request for each record. Types come from a single direct
      # query (#promoted_type_names) and not the generic #related walk, which
      # would summarize related places and so call #extras on them too.
      #
      # model_id and model_name identify the project_model a feature came
      # from. Features reached through Contained In can come from several other
      # models, and `contained_in` alone does not say which. admin_level is
      # #admin_level.
      def geojson_properties
        data = base_search_data
        {
          uuid: data[:uuid],
          slug: data[:slug],
          name: data[:name],
          model_type: data[:model_type],
          model_id: data[:model_id],
          model_name: data[:model_name],
          project: data[:project],
          types: promoted_type_names,
          admin_level: admin_level,
        }
      end

      def promoted_type_names
        types_relationship_name = PromotedRelationships.for(self).key(:types)
        return [] unless types_relationship_name

        rel = ::CoreDataConnector::ProjectModelRelationship.find_by(primary_model: project_model, name: types_relationship_name)
        return [] unless rel

        ::CoreDataConnector::Relationship.where(project_model_relationship: rel, primary_record: self).map { |r| r.related_record.name }
      end

      # Computed in SQL because the geometry is not always a bare Point (some
      # records are a GeometryCollection) and RGeo's GEOS binding has no
      # #centroid. PostGIS's ST_Centroid handles any geometry type.
      def centroid
        @centroid ||= ::CoreDataConnector::PlaceGeometry.connection.select_one(
          ::CoreDataConnector::PlaceGeometry.sanitize_sql_array([
            'SELECT ST_Y(ST_Centroid(geometry)) AS lat, ST_X(ST_Centroid(geometry)) AS lon ' \
              'FROM core_data_connector_place_geometries WHERE id = ?',
            place_geometry.id,
          ]),
        )
      end
    end
  end
end
