# frozen_string_literal: true

module OpenGeographies
  module V1
    class MediaContent < ::CoreDataConnector::MediaContent
      include Searchable

      searchable_index 'open_geographies_v1'

      self.table_name = 'core_data_connector_media_contents'

      # The IIIF Image API URLs (content_iiif_url, content_preview_url,
      # content_thumbnail_url: tiles, thumbnails, info.json) only apply to
      # images. For other content (audio, video, PDF, ...) those endpoints
      # return 404 because there is no image to derive tiles or a thumbnail
      # from, while /content, /download, /inline and /manifest still work. So
      # content_url depends on the content type.
      def extras
        if image?
          {
            preview: resource_description&.content_preview_url,
            thumbnail: resource_description&.content_thumbnail_url,
            content_url: resource_description&.content_iiif_url,
            manifest_url:,
          }
        else
          {
            content_url: resource_description&.content_inline_url,
            manifest_url:,
          }
        end
      end

      private

      # manifest_url itself stays nil-safe via the gem's own
      # `delegate ..., allow_nil: true` (see Resourceable) - matched here
      # with #to_s so a nil resource_description (no attached resource at
      # all) falls to the non-image branch rather than raising.
      def image?
        resource_description&.content_type.to_s.start_with?('image/')
      end
    end
  end
end
