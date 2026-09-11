# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      # A Place-class record playing the 'map_layer' role (see
      # ProjectModelRole) - GCA's "Map Layers"/"Topo Quads", generalized.
      # Gets its own index rather than joining open_geographies_v1: its
      # primary query is spatial-extent search (bbox), not point/text
      # search, and it carries a materially different document shape
      # (date/bearing/source instead of address/contained_in_place/...).
      class MapLayer < ::CoreDataConnector::Place
        include Searchable

        MAPPING_PATH = ::CoreDataConnector::OpenGeographies::Engine.root.join(
          'lib', 'core_data_connector_open_geographies', 'v1', 'es_mapping_map_layers.json'
        )
        MAPPING = JSON.parse(File.read(MAPPING_PATH), symbolize_names: true).freeze

        searchable_index 'open_geographies_v1_map_layers', mapping: MAPPING

        self.table_name = 'core_data_connector_places'

        # A bounding box, not a centroid (V1::Place's `extras`) - a map
        # layer's spatial extent is what a bbox/viewport query needs, not
        # its center point. ES geo_shape "envelope" wants
        # [[minLon, maxLat], [maxLon, minLat]] (top-left, bottom-right).
        def extras
          return {} unless place_geometry&.geometry

          box = bounding_box
          return {} unless box

          {
            bbox: {
              type: 'envelope',
              coordinates: [
                [box['min_lon'].to_f, box['max_lat'].to_f],
                [box['max_lon'].to_f, box['min_lat'].to_f],
              ],
            },
          }
        end

        private

        # SQL, not RGeo, for the same reason V1::Place#centroid uses it:
        # ST_XMin/XMax/YMin/YMax handle any geometry type uniformly
        # (Point, Polygon, GeometryCollection, ...), where RGeo's Ruby-level
        # API doesn't expose this consistently across geometry types.
        def bounding_box
          ::CoreDataConnector::PlaceGeometry.connection.select_one(
            ::CoreDataConnector::PlaceGeometry.sanitize_sql_array([
              'SELECT ST_XMin(geometry) AS min_lon, ST_XMax(geometry) AS max_lon, ' \
                'ST_YMin(geometry) AS min_lat, ST_YMax(geometry) AS max_lat ' \
                'FROM core_data_connector_place_geometries WHERE id = ?',
              place_geometry.id,
            ]),
          )
        end
      end
    end
  end
end
