# frozen_string_literal: true

require 'net/http'

module CoreDataConnector
  module OpenGeographies
    # Cache of a Place's administrative hierarchy (country/state/county-
    # equivalent/...) as reverse-geocoded from GeoNames, keyed on place_id.
    # Not v1-specific - any future indexing scheme that wants this data reads
    # from the same cache rather than re-deriving it.
    #
    # This exists instead of curator-defined "Contained In" relationships to
    # county-like records: those still work and still win when a curator has
    # actually built them out (see V1::Searchable's promoted `contained_in_place`),
    # but most curators don't want to hand-build a Counties model just to get
    # basic geographic faceting. `administrative_area` is populated for every
    # place with geometry, no curator effort required, and deliberately kept
    # separate from `contained_in_place` - GeoNames features aren't local OG
    # records, so they get no uuid/slug and nothing to link to.
    class GeonamesHierarchy < ApplicationRecord
      self.table_name = 'core_data_connector_open_geographies_geonames_hierarchies'

      ENDPOINT = 'http://api.geonames.org/extendedFindNearbyJSON'
      # "A" = administrative boundary (country/state/county/...) per GeoNames'
      # feature class scheme - this is what filters out the populated-place
      # entry (the city/town itself) that extendedFindNearbyJSON also returns,
      # since that's redundant with the OG place's own name.
      ADMIN_FEATURE_CLASS = 'A'
      TIMEOUT = 5 # seconds - a slow GeoNames response shouldn't hang indexing

      validates :place_id, presence: true, uniqueness: true
      validates :lat, :lng, presence: true

      class << self
        # Returns the cached hierarchy for `place_id`, refreshing from GeoNames
        # first if there's no cache row yet or the given lat/lng has moved from
        # what's cached (i.e. the place's geometry changed). A live GeoNames
        # failure falls back to whatever's cached (possibly stale, possibly
        # nothing) rather than raising - a missing/stale facet is far cheaper
        # than a broken index run.
        def lookup(place_id:, lat:, lng:)
          cached = find_by(place_id:)
          return cached.hierarchy if cached && !cached.stale?(lat, lng)

          fetched = fetch(lat:, lng:)
          return cached&.hierarchy || [] if fetched.nil?

          record = cached || new(place_id:)
          record.update!(lat:, lng:, hierarchy: fetched, fetched_at: Time.current)
          fetched
        end

        # nil on any failure (network, timeout, non-2xx, bad JSON) so callers
        # can distinguish "GeoNames had nothing here" ([]) from "couldn't ask" (nil).
        #
        # extendedFindNearbyJSON answers in one of two shapes, and which one
        # you get isn't a corner case - checked against 15 real HRCGA church
        # locations and every single one came back as `address`, zero as
        # `geonames`. The `geonames` array (parse_geonames_shape) is what
        # shows up for less-precise points; `address` (parse_address_shape)
        # is GeoNames' integrated US Census street-level reverse-geocoder,
        # which kicks in whenever a point resolves close enough to a mapped
        # street address - true for essentially any real building location,
        # not an edge case at all.
        def fetch(lat:, lng:)
          username = ENV.fetch('GEONAMES_USERNAME')
          uri = URI(ENDPOINT)
          uri.query = URI.encode_www_form(lat:, lng:, username:)

          response = Net::HTTP.start(uri.host, uri.port, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
            http.get(uri)
          end
          return unless response.is_a?(Net::HTTPSuccess)

          data = JSON.parse(response.body)
          # GeoNames error responses (bad username, rate limit, ...) come back
          # as 200 OK with a `status` key instead of either real shape - guard
          # against silently caching an empty hierarchy for what's actually a failure.
          return if data['status']

          if data['geonames']
            parse_geonames_shape(data['geonames'])
          elsif data['address']
            parse_address_shape(data['address'])
          else
            []
          end
        rescue StandardError => e
          Rails.logger.warn("[OpenGeographies] GeoNames lookup failed for #{lat},#{lng}: #{e.message}")
          nil
        end

        private

        def parse_geonames_shape(features)
          features
            .select { |feature| feature['fcl'] == ADMIN_FEATURE_CLASS }
            .map do |feature|
              {
                level: feature['fcode'],
                name: feature['name'],
                geonames_id: feature['geonameId'].to_s,
                geonames_url: "https://www.geonames.org/#{feature["geonameId"]}",
              }
            end
        end

        # No geonameId comes back at this level of detail, so geonames_id/
        # geonames_url are nil here - an honest reflection of what GeoNames
        # actually gave us, not a fabricated link. Levels are labeled with
        # the same fcode vocabulary as parse_geonames_shape (ADM2/ADM1/PCLI)
        # so callers see one consistent scheme regardless of which shape
        # answered. countryCode ("US"), not a spelled-out country name -
        # this shape doesn't give one, and guessing a name from the code
        # would only work reliably for a handful of countries.
        def parse_address_shape(address)
          [
            address['adminName2'].presence && { level: 'ADM2', name: address['adminName2'], geonames_id: nil, geonames_url: nil },
            address['adminName1'].presence && { level: 'ADM1', name: address['adminName1'], geonames_id: nil, geonames_url: nil },
            address['countryCode'].presence && { level: 'PCLI', name: address['countryCode'], geonames_id: nil, geonames_url: nil },
          ].compact
        end
      end

      def stale?(current_lat, current_lng)
        lat.to_f.round(6) != current_lat.to_f.round(6) || lng.to_f.round(6) != current_lng.to_f.round(6)
      end

      # jsonb round-trips through Postgres with string keys, not the symbol
      # keys .fetch builds - without this override, a cache hit silently
      # returns { "name" => ... } while a fresh fetch returns { name: ... },
      # so callers doing hierarchy.first[:name] get nil half the time
      # depending on whether the cache was warm. Symbolizing here means
      # every caller gets the same shape regardless of cache state.
      def hierarchy
        super&.map(&:symbolize_keys)
      end
    end
  end
end
