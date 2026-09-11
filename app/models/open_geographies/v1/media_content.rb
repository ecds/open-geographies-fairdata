# frozen_string_literal: true

module OpenGeographies
  module V1
    class MediaContent < ::CoreDataConnector::MediaContent
      include Searchable

      searchable_index 'open_geographies_v1'

      self.table_name = 'core_data_connector_media_contents'

      # The IIIF Image API (content_iiif_url/content_preview_url/
      # content_thumbnail_url - tiling, thumbnails, info.json) only applies
      # to actual images. For anything else (audio, video, PDF, ...) those
      # endpoints 404 by design - there's no image to derive a tile or
      # thumbnail from. Confirmed live against a real audio record: /iiif,
      # /preview, /thumbnail, /info all 404, while /content, /download,
      # /inline, and /manifest (the Presentation API, which describes it
      # correctly as a Sound annotation) all work fine. So content_url
      # needs to be content-type aware, not a blind IIIF Image API request
      # for every record regardless of what it actually is.
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
