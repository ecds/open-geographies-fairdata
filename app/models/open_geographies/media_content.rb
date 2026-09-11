# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class MediaContent < ::CoreDataConnector::MediaContent
      include Searchable

      self.table_name = 'core_data_connector_media_contents'

      private

      def extras
        {
          preview: resource_description.content_preview_url,
          thumbnail: resource_description.content_thumbnail_url,
          full: resource_description.content_iiif_url,
          manifest: manifest_url,
        }
      end
    end
  end
end
