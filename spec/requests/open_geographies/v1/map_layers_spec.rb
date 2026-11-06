# frozen_string_literal: true

require 'rails_helper'

# Uses the real open_geographies_v1_map_layers index, as map_layer_indexing_spec.rb
# does, because the annotation route finds its layer through a search.
RSpec.describe('OpenGeographies::V1::MapLayers', type: :request) do
  after do
    [OpenGeographies::V1::MapLayer, OpenGeographies::V1::Place].each do |klass|
      index = klass.searchkick_index
      index.delete if index.exists?
    end
  end

  let(:project) { create(:project) }
  let(:layer_model) do
    create(:place_model, project:).tap do |model|
      create(:project_model_role, project_model_record: model, role: 'map_layer')
    end
  end
  let(:layer) { create(:place, project_model: layer_model, name: 'Hilliard 1917') }

  # A IIIF georeference annotation page as it is stored in PlaceLayer#content.
  # Pretty-printed, so a response that re-encodes it would not match.
  let(:annotation) do
    JSON.pretty_generate(
      '@context' => 'http://iiif.io/api/extension/georef/1/context.json',
      'type' => 'AnnotationPage',
      'items' => [{ 'type' => 'Annotation', 'motivation' => 'georeferencing' }],
    )
  end

  def get_annotation(slug = 'hilliard-1917')
    OpenGeographies::V1::MapLayer.reindex(refresh: true)
    get("/open_geographies/v1/#{project.name.parameterize}/map_layers/#{slug}/annotation")
  end

  # #show and #annotation both find a layer by an exact match on `slugs`,
  # which needs a keyword mapping in es_mapping_map_layers.json.
  describe 'GET /v1/:project/map_layers/:slug' do
    it 'finds a layer by its slug' do
      layer

      OpenGeographies::V1::MapLayer.reindex(refresh: true)
      get("/open_geographies/v1/#{project.name.parameterize}/map_layers/hilliard-1917")

      expect(response).to(have_http_status(:ok))
      expect(response_json[:name]).to(eq('Hilliard 1917'))
    end
  end

  describe 'GET /v1/:project/map_layers/:slug/annotation' do
    it 'returns the stored annotation page exactly as stored' do
      create(:place_layer, place: layer, content: annotation)

      get_annotation

      expect(response).to(have_http_status(:ok))
      expect(response.media_type).to(eq('application/json'))
      expect(response.body).to(eq(annotation))
    end

    it 'is not found when the layer only has place layers with a url' do
      create(:place_layer, place: layer, url: 'https://example.org/hilliard-1917/annotation.json')

      get_annotation

      expect(response).to(have_http_status(:not_found))
    end

    it 'is not found when only a layer of another type has content' do
      create(:place_layer, place: layer, layer_type: 'raster', content: annotation)

      get_annotation

      expect(response).to(have_http_status(:not_found))
    end

    it 'skips a georeference place layer that only has a url' do
      create(:place_layer, place: layer, url: 'https://example.org/hilliard-1917/annotation.json')
      create(:place_layer, place: layer, content: annotation)

      get_annotation

      expect(response).to(have_http_status(:ok))
      expect(response.body).to(eq(annotation))
    end

    it 'is not found for an unknown slug' do
      create(:place_layer, place: layer, content: annotation)

      get_annotation('no-such-layer')

      expect(response).to(have_http_status(:not_found))
    end

    it 'is not found for an unpublished layer' do
      create(:place_layer, place: layer, content: annotation)
      layer.update_published(false)

      get_annotation

      expect(response).to(have_http_status(:not_found))
    end

    context 'when the project is not discoverable' do
      let(:project) { create(:project, discoverable: false) }

      it 'is not found' do
        create(:place_layer, place: layer, content: annotation)

        get_annotation

        expect(response).to(have_http_status(:not_found))
      end
    end
  end
end
