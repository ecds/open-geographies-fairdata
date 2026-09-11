# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Place < ::CoreDataConnector::Place
      include Searchable

      self.table_name = 'core_data_connector_places'

      private

      def extras
        {
          geometry: place_geometry&.to_geojson,
          names: place_names.map(&:name),
          place_layers: place_layers.map do |pl|
            {
              id: pl.id,
              name: pl.name,
              slug: pl.name.parameterize,
              type: pl.layer_type,
              url: pl.url,
              content: pl.content.nil? ? {} : JSON.parse(pl.content, symbolize_names: true),
            }
          end,
        }
      end
    end
  end
end
