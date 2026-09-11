# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Tour < ::CoreDataConnector::Instance
      include Searchable

      self.table_name = 'core_data_connector_instances'

      def search_data
        {
          id:,
          uuid:,
          name:,
          slug:,
          slugs:,
          project: project.name.parameterize,
          stops: stops,
          bounds:,
        }
      end

      def stops
        # stops_rel_model = ::CoreDataConnector::ProjectModelRelationship.find_by(primary_model: project_model, name: 'Stops')
        tour_stops = related[:stops].sort_by { |stop| stop[:order] }
        tour_stops.map.with_index do |stop, idx|
          place = Place.find(stop[:id])
          {
            title: place.name,
            slugs: place.slugs,
            slug: place.slug,
            id: place.id,
            position: idx + 1,
            next: neighbor(tour_stops[idx + 1]),
            previous: idx.zero? ? nil : neighbor(tour_stops[idx - 1]),
            lat: place.place_geometry.geometry.y,
            lng: place.place_geometry.geometry.x,
            description: place.user_defined_fields[:description][:value],
            address: place.user_defined_fields[:address][:value],
            media: stop_media(stop[:photographs]),
            splash: splash(stop),
          }
        end
      end

      def neighbor(stop)
        return if stop.nil?

        {
          id: stop[:id],
          slug: stop[:slug],
          title: stop[:name],
        }
      end

      def stop_media(media)
        return [] if media.nil? || media.empty?

        media.map do |medium|
          mc = MediaContent.find_by(uuid: medium[:uuid])
          {
            title: medium[:name],
            caption: mc.user_defined_fields.dig(:caption, :value),
            files: {
              original: medium[:full],
              mobile: medium[:full],
              tablet: medium[:full],
              desktop: medium[:full],
              lqip: medium[:preview],
            },
          }
        end
      end

      def splash(place)
        if place[:featured] && place[:featured][:photographs]
          return {
            title: place[:featured][:photographs][:name],
            caption: '',
            url: place[:featured][:photographs][:preview],
          }
        end
        {
          title: place[:photographs].first[:name],
          caption: '',
          url: place[:photographs].first[:preview],
        }
      end

      def bounds
        points = related[:stops].map do |stop|
          place = Place.find(stop[:id])
          place.place_geometry.geometry
        end

        factory = points.first&.factory
        combined = factory.collection(points)
        envelope = combined.envelope
        {
          west: envelope.exterior_ring.points.map(&:x).min,
          east: envelope.exterior_ring.points.map(&:x).max,
          south: envelope.exterior_ring.points.map(&:y).min,
          north: envelope.exterior_ring.points.map(&:y).max,
        }
      end
    end
  end
end
