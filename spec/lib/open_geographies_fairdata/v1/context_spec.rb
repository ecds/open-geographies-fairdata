# frozen_string_literal: true

require 'rails_helper'

# The JSON-LD context names every field a v1 document can carry. These checks
# fail when a field is added to a mapping, the template or a document without
# a term here. Curator-defined extras ({label, value} objects, *_facet, *_2)
# are local to a project and are not expected to have terms.
RSpec.describe('V1 JSON-LD context') do
  root = OpenGeographies::Engine.root.join('lib', 'open_geographies_fairdata', 'v1')
  terms = JSON.parse(File.read(root.join('context.jsonld')))['@context']

  # The terms in force inside `term`'s value: the outer ones plus any it scopes.
  scoped = lambda do |scope, term|
    definition = scope[term]
    definition.is_a?(Hash) && definition['@context'] ? scope.merge(definition['@context']) : scope
  end

  # Mapping properties, at any depth, with no term in scope.
  undefined_properties = lambda do |properties, scope, prefix|
    properties.flat_map do |key, property|
      path = [prefix, key].compact.join('.')
      missing = scope.key?(key) ? [] : [path]
      nested = property['properties'] ? undefined_properties.call(property['properties'], scoped.call(scope, key), path) : []
      missing + nested
    end
  end

  # Keys in a document, at any depth, with no term in scope. A JSON literal
  # (@json) is not looked into.
  undefined_keys = lambda do |value, scope, prefix|
    case value
    when Hash
      next [] if value.keys.map(&:to_s).sort == ['label', 'value']

      value.flat_map do |key, child|
        key = key.to_s
        next [] if key.start_with?('@')

        path = [prefix, key].compact.join('.')
        missing = scope.key?(key) ? [] : [path]
        definition = scope[key]
        next missing if definition.is_a?(Hash) && definition['@type'] == '@json'

        missing + undefined_keys.call(child, scoped.call(scope, key), path)
      end
    when Array
      value.flat_map { |item| undefined_keys.call(item, scope, prefix) }.uniq
    else
      []
    end
  end

  it 'is a JSON-LD 1.1 context' do
    expect(terms['@version']).to(eq(1.1))
  end

  ['es_mapping.json', 'es_mapping_map_layers.json'].each do |file|
    it "has a term for every field in #{file}" do
      properties = JSON.parse(File.read(root.join(file))).dig('mappings', 'properties')

      expect(undefined_properties.call(properties, terms, nil)).to(be_empty)
    end
  end

  it 'has a term for every key the template promotes to' do
    template = JSON.parse(File.read(root.join('canonical_template.json')))
    promoted = template['project_models'].flat_map do |model|
      (model['user_defined_fields'] || []) + (model['project_model_relationships'] || [])
    end.filter_map { |entry| entry.dig('og', 'promote') }.uniq

    missing = promoted.reject do |path|
      scope = terms
      path.split('.').all? do |segment|
        found = scope.key?(segment)
        scope = scoped.call(scope, segment)
        found
      end
    end

    expect(missing).to(be_empty)
  end

  it 'has a term for every key in a place and a media document' do
    project = create(:project)
    place_model = create(:place_model, project:, name: 'Places')
    place = create(:place, project_model: place_model, name: 'Evergreen Church')
    create(:place_geometry, place:)

    county_model = create(:place_model, project:)
    county = create(:place, project_model: county_model, name: 'Grady County')
    create(:place_geometry, place: county)
    contained = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false)
    create(:relationship, project_model_relationship: contained, primary_record: place, related_record: county)

    types_model = create(:taxonomy_model, project:)
    types = create(:project_model_relationship, primary_model: place_model, related_model: types_model, name: 'Types', multiple: true)
    create(:relationship, project_model_relationship: types, primary_record: place, related_record: create(:taxonomy, project_model: types_model, name: 'Church'))

    media_model = create(:place_model, project:, name: 'Media', model_class: 'CoreDataConnector::MediaContent')
    photo = create(:media_content, project_model: media_model, name: 'A Photo')
    media = create(:project_model_relationship, primary_model: place_model, related_model: media_model, name: 'Media', multiple: true)
    create(:relationship, project_model_relationship: media, primary_record: place, related_record: photo, order: 1)

    place_document = OpenGeographies::V1::Place.find(place.id).search_data
    media_document = OpenGeographies::V1::MediaContent.find(photo.id).search_data

    expect(undefined_keys.call(place_document, terms, nil)).to(be_empty)
    expect(undefined_keys.call(media_document, terms, nil)).to(be_empty)
  end
end
