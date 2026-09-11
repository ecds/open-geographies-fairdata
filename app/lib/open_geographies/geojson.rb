# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Geojson
      attr_reader :records

      def initialize(records, type)
        @records = records
        @type = type || 'places'
        # @osm_rel_model = CoreDataConnector::ProjectModelRelationship.find(57)
      end

      def feature_collection
        collection = {
          type: 'FeatureCollection',
          features: [],
        }

        progressbar = Progressbar.new(@records.count, @type)
        @records.each do |record|
          next unless record.is_a?(CoreDataConnector::Place)

          documenter = CoreDataConnector::OpenGeographies::Document.new(record)

          properties = documenter.document
          geometry = doc.delete(:geometry)
          feature = {
            type: 'feature',
            properties:,
            geometry:,
          }

          collection[:features].push(feature)
          progressbar.increment
        end
        progressbar.finish
        collection[:features].flatten.uniq
      end

      def write_geojson(path = "./#{@type}.json")
        File.write(path, JSON.dump({ type: 'FeatureCollection', features: feature_collection }))
        File.exist?(path)
      end

      # def osm_class(record)
      #   osm_item = CoreDataConnector::Relationship.find_by(
      #     project_model_relationship: @osm_rel_model,
      #     related_record: record
      #   )
      #   return @type.singularize if osm_item.nil?

      #   osm_props = JSON.parse(
      #     osm_item.primary_record.user_defined["8f35ead2-fa02-4273-8c21-90fea494f362"]
      #   )
      #   osm_props["place"] || osm_props["water"] || osm_props["waterway"] || osm_props["natural"]
      # end
    end
  end
end
