# frozen_string_literal: true

require 'rails_helper'

RSpec.describe(CoreDataConnector::OpenGeographies::V1::PromotedRelationships) do
  describe '.template_model_name_for' do
    it 'resolves a Place with no ProjectModelRole to "Places" by default' do
      project_model = create(:place_model)
      place = create(:place, project_model:)
      v1_place = CoreDataConnector::OpenGeographies::V1::Place.find(place.id)

      expect(described_class.template_model_name_for(v1_place)).to(eq('Places'))
    end

    it 'resolves a Place with an explicit map_layer ProjectModelRole to "Map Layers"' do
      project_model = create(:place_model)
      create(:project_model_role, project_model_record: project_model, role: 'map_layer')
      place = create(:place, project_model:)
      v1_map_layer = CoreDataConnector::OpenGeographies::V1::MapLayer.find(place.id)

      expect(described_class.template_model_name_for(v1_map_layer)).to(eq('Map Layers'))
    end

    it 'resolves unambiguous superclasses directly, without touching the database' do
      expect(described_class.template_model_name_for(CoreDataConnector::OpenGeographies::V1::Work.new)).to(eq('Works'))
      expect(described_class.template_model_name_for(CoreDataConnector::OpenGeographies::V1::Person.new)).to(eq('People'))
      expect(described_class.template_model_name_for(CoreDataConnector::OpenGeographies::V1::Organization.new)).to(eq('Organizations'))
      expect(described_class.template_model_name_for(CoreDataConnector::OpenGeographies::V1::MediaContent.new)).to(eq('Media'))
      expect(described_class.template_model_name_for(CoreDataConnector::OpenGeographies::V1::Taxonomy.new)).to(eq('Types'))
    end
  end

  describe '.for' do
    it 'returns the Places relationship promotion registry, keyed by canonical relationship name' do
      project_model = create(:place_model)
      place = create(:place, project_model:)
      v1_place = CoreDataConnector::OpenGeographies::V1::Place.find(place.id)

      expect(described_class.for(v1_place)).to(eq(
        'Types' => :types,
        'Contained In' => :contained_in_place,
        'Media' => :media,
        'Works' => :works,
        'People' => :people,
        'Related Places' => :places,
        'Map Layers' => :map_layers,
      ))
    end

    it 'returns {} for a template entry with no promoted relationships (People)' do
      project_model = create(:place_model, model_class: 'CoreDataConnector::Person')
      expect(described_class.for(CoreDataConnector::OpenGeographies::V1::Person.new(project_model:))).to(eq({}))
    end
  end

  describe '.udfs_for' do
    it 'returns dotted promote paths as bare strings, not symbols' do
      layer_model = create(:place_model)
      create(:project_model_role, project_model_record: layer_model, role: 'map_layer')
      layer_place = create(:place, project_model: layer_model)
      v1_map_layer = CoreDataConnector::OpenGeographies::V1::MapLayer.find(layer_place.id)

      expect(described_class.udfs_for(v1_map_layer)).to(eq(
        'Date' => 'date',
        'Bearing' => 'bearing',
        'Source Type' => 'source.type',
        'Source URLs' => 'source.urls',
        'Description' => 'description',
      ))
    end
  end

  describe '.model_type_for' do
    it 'maps Places to "place" and Map Layers to "map_layer" via the same ProjectModelRole disambiguation' do
      project_model = create(:place_model)
      place = create(:place, project_model:)
      v1_place = CoreDataConnector::OpenGeographies::V1::Place.find(place.id)
      expect(described_class.model_type_for(v1_place)).to(eq('place'))

      layer_model = create(:place_model)
      create(:project_model_role, project_model_record: layer_model, role: 'map_layer')
      layer_place = create(:place, project_model: layer_model)
      v1_map_layer = CoreDataConnector::OpenGeographies::V1::MapLayer.find(layer_place.id)
      expect(described_class.model_type_for(v1_map_layer)).to(eq('map_layer'))
    end

    it 'returns "unknown" for a model_class the template does not cover' do
      project_model = create(:place_model, model_class: 'CoreDataConnector::Item')
      expect(described_class.model_type_for(CoreDataConnector::OpenGeographies::V1::Item.new(project_model:))).to(eq('unknown'))
    end
  end
end
