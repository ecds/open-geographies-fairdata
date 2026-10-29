# frozen_string_literal: true

require 'rails_helper'

# Uses the real open_geographies_v1_map_layers index, since only an index write
# shows whether es_mapping_map_layers.json accepts a document.
RSpec.describe('V1 MapLayer Elasticsearch indexing') do
  after do
    index = OpenGeographies::V1::MapLayer.searchkick_index
    index.delete if index.exists?
  end

  let(:project) { create(:project) }
  let(:layer_model) do
    create(:place_model, project:).tap do |model|
      create(:project_model_role, project_model_record: model, role: 'map_layer')
    end
  end

  def find_by_slug(slug)
    OpenGeographies::V1::MapLayer.search('*', where: { slug: }, load: false).first
  end

  it 'indexes a fuzzy Date as its first day under date, with the whole value under date_2' do
    fuzzy_date = { 'start_date' => '1895-01-01', 'end_date' => '1895-12-31', 'accuracy' => 'year', 'range' => false, 'description' => '1895' }
    udf = create(:user_defined_field, defineable: layer_model, column_name: 'Date', data_type: 'FuzzyDate')
    create(:place, project_model: layer_model, name: 'Sanborn Sheet 4', user_defined: { udf.uuid => fuzzy_date })

    OpenGeographies::V1::MapLayer.reindex(refresh: true)

    result = find_by_slug('sanborn-sheet-4')
    expect(result[:date]).to(eq('1895-01-01'))
    expect(result[:date_2]).to(eq({ 'label' => 'Date', 'value' => fuzzy_date }))
  end

  it 'does not map a date-looking text value as a date, so later text values still index' do
    udf = create(:user_defined_field, defineable: layer_model, column_name: 'Survey', data_type: 'String')
    create(:place, project_model: layer_model, name: 'Quad A', user_defined: { udf.uuid => '1903-04-01' })
    OpenGeographies::V1::MapLayer.reindex(refresh: true)

    second = create(:place, project_model: layer_model, name: 'Quad B', user_defined: { udf.uuid => 'resurveyed' })
    OpenGeographies::V1::MapLayer.find(second.id).reindex(refresh: true)

    expect(find_by_slug('quad-b')[:survey]).to(eq({ 'label' => 'Survey', 'value' => 'resurveyed' }))
  end

  it 'creates the index with date detection off and nested objects unmapped, while top-level fields stay mapped' do
    udf = create(:user_defined_field, defineable: layer_model, column_name: 'Survey', data_type: 'String')
    create(:place, project_model: layer_model, name: 'Quad C', user_defined: { udf.uuid => 'original' })

    OpenGeographies::V1::MapLayer.reindex(refresh: true)

    mappings = OpenGeographies::V1::MapLayer.searchkick_index.mapping.values.first['mappings']
    expect(mappings.dig('properties', 'survey', 'properties', 'value', 'type')).to(eq('text'))
    expect(mappings['date_detection']).to(be(false))
    expect(mappings['dynamic_templates'].first.keys).to(eq(['nested_objects_unmapped']))
  end
end
