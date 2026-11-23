# frozen_string_literal: true

require 'rails_helper'

RSpec.describe(OpenGeographies::V1::MediaContent) do
  describe '#extras' do
    it 'uses the IIIF Image API URLs for an image' do
      media = create(:media_content)
      v1_media = OpenGeographies::V1::MediaContent.find(media.id)
      v1_media.resource_description = TripleEyeEffable::ResourceDescription.new(resource_id: 'abc123', content_type: 'image/jpeg')

      extras = v1_media.extras
      expect(extras[:content_url]).to(end_with('/abc123/iiif'))
      expect(extras[:preview]).to(end_with('/abc123/preview'))
      expect(extras[:thumbnail]).to(end_with('/abc123/thumbnail'))
    end

    it "doesn't request the IIIF Image API for non-image media - it 404s for anything that isn't an actual image" do
      media = create(:media_content)
      v1_media = OpenGeographies::V1::MediaContent.find(media.id)
      v1_media.resource_description = TripleEyeEffable::ResourceDescription.new(resource_id: 'abc123', content_type: 'audio/mpeg')

      extras = v1_media.extras
      expect(extras[:content_url]).to(end_with('/abc123/inline'))
      expect(extras).not_to(include(:preview, :thumbnail))
    end

    it 'falls back to the non-image shape with no resource_description at all, without raising' do
      media = create(:media_content)
      v1_media = OpenGeographies::V1::MediaContent.find(media.id)

      expect { v1_media.extras }.not_to(raise_error)
      expect(v1_media.extras[:content_url]).to(be_nil)
    end
  end
end
