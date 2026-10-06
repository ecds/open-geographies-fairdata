# frozen_string_literal: true

module OpenGeographies
  module V1
    class MapLayersController < ApplicationController
      def index
        @records = Array(
          MapLayer.search(
            '*',
            where: where_clause,
            load: false,
          ),
        )
        render(json: @records)
      end

      def show
        @record = MapLayer.search(
          '*',
          where: { model_type: 'map_layer', project_id: project_id, slugs: params[:slug] },
          limit: 1,
          load: false,
        ).first
        render(json: @record, status: :ok) and return if @record

        render(json: {}, status: :not_found)
      end

      private

      def where_clause
        clause = { model_type: 'map_layer', project_id: project_id }
        clause[:bbox] = { geo_shape: { type: 'envelope', coordinates: bbox_coordinates, relation: 'intersects' } } if params[:bbox].present?
        clause
      end

      # Parses ?bbox=minLon,minLat,maxLon,maxLat, the common bounding box
      # parameter format (the same string Leaflet's
      # getBounds().toBBoxString() produces), into the upper-left and
      # lower-right corners of an Elasticsearch envelope.
      def bbox_coordinates
        min_lon, min_lat, max_lon, max_lat = params[:bbox].split(',').map(&:to_f)
        [[min_lon, max_lat], [max_lon, min_lat]]
      end
    end
  end
end
