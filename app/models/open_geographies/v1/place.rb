# frozen_string_literal: true

require 'rgeo/geo_json'

module OpenGeographies
  module V1
    class Place < ::CoreDataConnector::Place
      include Searchable

      searchable_index 'open_geographies_v1'

      self.table_name = 'core_data_connector_places'

      class << self
        # Streams GeoJSON Features for every place in `project_model` -
        # for a bulk vector-tile pipeline (tippecanoe/pmtiles), not the ES
        # index (see #geojson_features for why this needs its own path
        # rather than reusing #extras/#search_data directly). Batched via
        # find_each so a multi-thousand-record atlas (Georgia Coast has
        # 5,000+) doesn't load every record into memory at once. Yields
        # each Feature if a block is given; otherwise returns an
        # Enumerator - `.to_a` that into a FeatureCollection, or stream it
        # straight into whatever builds the tiles. This engine owns the
        # data shape, deliberately not how it gets tiled or published -
        # see core-data-cloud's pmtiles pipeline for that.
        #
        # Also emits each exported place's whole Contained In chain, not
        # just the immediate target - a church's county, that county's own
        # state, and so on up until something has no further Contained In
        # relationship. None of these are members of `project_model`,
        # often not even the same project (the "Administrative Areas"
        # pattern from this session), so they'd never appear in this
        # export otherwise. Deduped by id, tracked across the whole run
        # (not just within one place's own chain): most places in a
        # `project_model` share the same county and state, and a naive
        # per-place emit would write those same boundaries hundreds of
        # times over. Marked `contained_in: true` in its own properties,
        # distinct from every property a real #geojson_properties call
        # ever produces, so a map client can tell an admin-area shape
        # apart from this project_model's own places without guessing
        # from project/name.
        #
        # Walking continues past an unpublished link even though it isn't
        # itself emitted (see the #published note below) - a hidden county
        # shouldn't also hide the state above it, and visited_area_ids
        # doubles as cycle protection regardless of publish state, so a
        # malformed Contained In loop can't hang this in an infinite walk.
        # See #emit_admin_area_feature for why every member geometry of an
        # admin area is emitted, not just its boundary shape.
        #
        # Scoped to #published, matching Searchable#should_index? (the ES
        # indexing gate) - the raw ActiveRecord query here never goes
        # through Searchkick at all, so nothing enforces that gate unless
        # this does it directly. Matters more here than for search: this
        # pipeline's output is uploaded straight to a public S3 bucket
        # behind CloudFront (see core-data-cloud's rake task), so an
        # unpublished record leaking in isn't just an inconsistency, it's
        # a real exposure - a draft a curator deliberately hid, baked into
        # a public file. Each link in a Contained In chain gets the same
        # check before being emitted, for the same reason.
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

        # Every member of #geojson_features' own explode, not just the
        # boundary shape - an admin area combined this session (Georgia's
        # counties) carries a GeometryCollection of its original WordPress
        # Point *and* its real boundary Polygon, and both are wanted: the
        # Polygon is what renders the area, and the Point is what a
        # client's label layer anchors text to (a MapLibre symbol layer
        # placed directly on a Polygon can auto-place at a computed
        # interior point, but that's not always where a curator's own
        # marker was, and not every consumer wants to rely on it). Both
        # get the same `contained_in: true` tag - a client distinguishes
        # the two by geometry type (`["==", ["geometry-type"], "Point"]`
        # for a label symbol layer), the same way it already tells an
        # admin area apart from a --place-model place at all.
        #
        # `tippecanoe: { minzoom: 0 }` is a top-level GeoJSON Feature
        # member Tippecanoe itself reads (sibling of properties/geometry,
        # stripped before it becomes a tile attribute) - not decoration,
        # load-bearing. Verified empirically (a synthetic reproduction of
        # this atlas's real proportions - 78 place points + 29 admin
        # points): og_pmtiles.rake's --drop-densest-as-needed thins ALL
        # points in the layer together by density, admin or not, so at a
        # whole-state zoom only ~10 of 29 counties survived into the tile
        # at all - no MapLibre paint/layout setting can render a feature
        # that was never in the tile. Giving a feature its own explicit
        # tippecanoe.minzoom exempts *only that feature* from the
        # automatic density-based drop decision (confirmed: with this pin,
        # 29/29 admin features survived at the same zoom, while ordinary
        # place points kept their own natural thinning, unaffected -
        # exactly the point, since a 5,000+-point atlas like Georgia Coast
        # still wants that thinning for its own places). Tried routing
        # admin features into their own separate tippecanoe.layer first,
        # expecting an independent per-layer size/density budget - verified
        # empirically that tippecanoe's density thinning is computed across
        # the whole tile regardless of output layer, so that alone changed
        # nothing (still ~10/29) and isn't the mechanism to reach for here.
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

      def slug
        base = super
        suffix = containing_area_slug
        suffix ? "#{base}-#{suffix}" : base
      end

      # The un-suffixed value stays in `slugs` too (alongside the suffixed
      # one) so an existing link built before this record ever had a
      # containing area resolved (or before this feature existed) still
      # resolves - see Searchable#slugs's own doc comment for why `slugs`
      # is deliberately more permissive than the single canonical `slug`.
      def slugs
        base_slugs = super
        suffix = containing_area_slug
        return base_slugs unless suffix

        (base_slugs + base_slugs.map { |candidate| "#{candidate}-#{suffix}" }).uniq
      end

      # One GeoJSON Feature per underlying geometry, not per record: a
      # GeometryCollection (a non-contiguous record - Georgia Coast has
      # 1,766 of them, e.g. a barrier island's separate islets) explodes
      # into one Feature per member geometry, matching what a map
      # renderer actually wants - independent shapes, not one indivisible
      # multi-part blob a click can't distinguish. #extras only ever
      # computes a centroid point (right for a search-facing summary;
      # search doesn't need the actual shape), so this reads the real
      # geometry straight from place_geometry instead.
      #
      # Properties are a deliberately flat subset of #search_data (not the
      # full nested document - unlike an ES summary, a vector-tile
      # feature's properties should stay small) using the exact same
      # canonical field names/values as everywhere else in v1 - "follows
      # the OG schema" by construction, not by a second hand-maintained
      # mapping (compare core-data-cloud's pre-v1, GCA-specific
      # Ecds::Geojson, which hardcodes its own per-atlas UUID/
      # related_model_id property mapping - this is the generalized
      # replacement, any v1 atlas gets the same properties for free).
      def geojson_features
        return [] unless place_geometry&.geometry

        encoded = RGeo::GeoJSON.encode(place_geometry.geometry)
        geometries = encoded['type'] == 'GeometryCollection' ? encoded['geometries'] : [encoded]

        geometries.map do |geometry|
          { type: 'Feature', properties: geojson_properties, geometry: }
        end
      end

      # The curator-built hierarchy, resolved the same way #related_to
      # would for the promoted relationship, but standalone and public:
      # #slug needs it before #related ever runs (as part of
      # #base_search_data), and #each_geojson_feature needs it on an
      # explicit receiver (another place's own #contained_in_place, not
      # self's) to pull each exported place's containing admin area into
      # the PMTiles output too - private wouldn't allow that second case.
      def contained_in_place
        rel_name = PromotedRelationships.for(self).key(:contained_in_place)
        return unless rel_name

        rel = ::CoreDataConnector::ProjectModelRelationship.find_by(primary_model: project_model, name: rel_name)
        return unless rel

        relationship = ::CoreDataConnector::Relationship.find_by(project_model_relationship: rel, primary_record: self)
        relationship && self.class.find(relationship.related_record_id)
      end

      private

      # GeoNames' fcode vocabulary, most-specific first (see
      # GeonamesHierarchy) - only ADM1/ADM2/PCLI actually come back from
      # the reverse-geocoder today, but ranking the full scheme costs
      # nothing and means a future finer level (ADM3+) is picked up
      # automatically instead of silently falling through the .fetch
      # default.
      GEONAMES_LEVEL_SPECIFICITY = { 'ADM5' => 0, 'ADM4' => 1, 'ADM3' => 2, 'ADM2' => 3, 'ADM1' => 4, 'PCLI' => 5 }.freeze

      # Memoized: #slug, #slugs, and #extras each independently want the
      # containing-area name for one record's #search_data - without this,
      # a single index write pays for ST_Centroid three times over.
      #
      # Reads #contained_in_place's own #name, not its #slug - calling
      # #slug would recurse into this same suffixing on the target itself
      # and compound at every level of a hierarchy a curator built deep
      # (county's own "Contained In" -> state would otherwise turn
      # "putnam-county" into "putnam-county-georgia", one level deeper
      # than intended).
      #
      # Skips entirely for a top-level admin area (a state/PCLI-equivalent
      # record whose own Admin Level UDF is ADM1 or broader) - the
      # disambiguation this exists for only makes sense for records that
      # can plausibly collide by name (churches; counties, if this pattern
      # is ever reused for a multi-state atlas), and a state has nothing
      # real to disambiguate against. Real bug this guard fixes: Georgia
      # (ADM1) has no Contained In relationship of its own, so this fell
      # through to #geonames_area_name, which reverse-geocodes the state's
      # *centroid* and returns whatever small ADM2 unit happens to overlap
      # that single point - "georgia-twiggs", a county picked essentially
      # at random by where the centroid landed, not a real containing
      # relationship. Ordinary places (no Admin Level UDF at all, e.g. a
      # church) are unaffected - #admin_level is nil for them, which never
      # matches the ADM1-or-broader check below.
      def containing_area_slug
        return if top_level_admin_area?

        @containing_area_slug ||= (contained_in_place&.name || geonames_area_name)&.parameterize
      end

      def top_level_admin_area?
        GEONAMES_LEVEL_SPECIFICITY.fetch(admin_level, -1) >= GEONAMES_LEVEL_SPECIFICITY.fetch('ADM1')
      end

      # The record's own Admin Level UDF value (ADM1/ADM2/PCLI/...), read
      # through the same #user_defined_fields mechanism every other UDF
      # uses - not a hardcoded UUID, so this works for any project_model
      # that happens to define a UDF named "Admin Level", not just today's
      # Administrative Areas one. nil for every record whose project_model
      # has no such field (every real place, e.g. a church).
      def admin_level
        user_defined_fields.dig(:admin_level, :value)
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

      # Deliberately not #search_data: that calls #extras, which does a
      # live GeoNames HTTP lookup (GeonamesHierarchy.lookup) for any
      # record with no cached hierarchy yet - a few seconds' latency the
      # ES indexer happily pays once per record, but ruinous multiplied
      # across a bulk export of thousands (found live: a 10-record sample
      # against Georgia Coast Atlas didn't finish in two minutes). None of
      # these properties need administrative_area/geo anyway - the real
      # geometry comes from place_geometry directly, not the centroid
      # #extras computes for the ES index. #base_search_data alone is
      # cheap (local attribute reads only); #promoted_type_names below is
      # a direct, single-relationship query rather than the generic
      # #related walk, which would call #summarize - and so #extras - on
      # every *other* promoted relationship's related records too
      # (County, Map Layers, ... - several of Georgia Coast's own Places
      # relationships point at other Place records).
      #
      # model_id/model_name are #base_search_data's already-computed
      # project_model.id/name, surfaced here so a client (or a human
      # inspecting the exported GeoJSON) can tell which project_model a
      # given feature actually came from - the og_pmtiles rake task
      # resolves one project_model from its --place-model option, but
      # .each_geojson_feature also walks in Contained In targets from
      # whatever *other* project_model each one belongs to (the
      # "Administrative Areas" pattern), and those show up in the same
      # flat feature stream with no other property naming their source.
      # `contained_in` alone only says "not a place from --place-model" -
      # it doesn't say which model the feature IS from, and a chain can
      # walk through more than one (a county, then that county's own
      # differently-modeled state).
      #
      # admin_level is #admin_level below (see its own doc comment).
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

      # SQL, not RGeo, computes this: geometry isn't always a bare Point (some
      # records store a GeometryCollection), and RGeo's GEOS binding here
      # doesn't expose a Ruby-level #centroid at all (raises NoMethodError) -
      # only PostGIS's ST_Centroid reliably handles arbitrary geometry types,
      # which is exactly why CoreDataConnector::Place.centroid_function
      # computes this in SQL rather than Ruby too.
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
