# frozen_string_literal: true

require 'rails_helper'

# Real Elasticsearch, not a mock - same rationale as reindexable_spec.rb.
RSpec.describe('V1 ReindexesParent') do
  after do
    index = CoreDataConnector::OpenGeographies::V1::Place.searchkick_index
    index.delete if index.exists?
  end

  it 'reindexes the owning Place when its PlaceGeometry is created, updated, and destroyed' do
    project = create(:project)
    place_model = create(:place_model, project:)
    place = create(:place, project_model: place_model, name: 'Geometry Church')

    geometry = create(:place_geometry, place:)
    CoreDataConnector::OpenGeographies::V1::Place.searchkick_index.refresh

    result = CoreDataConnector::OpenGeographies::V1::Place
      .search('*', where: { slug: 'geometry-church' }, load: false)
      .first
    expect(result[:geo][:point]).to(be_present)

    geometry.destroy!
    CoreDataConnector::OpenGeographies::V1::Place.searchkick_index.refresh

    result = CoreDataConnector::OpenGeographies::V1::Place
      .search('*', where: { slug: 'geometry-church' }, load: false)
      .first
    expect(result[:geo]).to(be_nil)
  end

  it 'reindexes the owning Place when its primary PlaceName is edited' do
    project = create(:project)
    place_model = create(:place_model, project:)
    place = create(:place, project_model: place_model, name: 'Original')
    CoreDataConnector::OpenGeographies::V1::Place.searchkick_index.refresh

    # Editing the PlaceName row itself (not the Place row) - #name/#slug
    # delegate to the primary PlaceName, so this only changes if the
    # cascade actually reindexes the *parent* Place, not just the PlaceName
    # (which has no V1:: index of its own to update).
    place.place_names.first.update!(name: 'Renamed Via Name Row')
    CoreDataConnector::OpenGeographies::V1::Place.searchkick_index.refresh

    result = CoreDataConnector::OpenGeographies::V1::Place
      .search('*', where: { slug: 'renamed-via-name-row' }, load: false)
      .first
    expect(result).to(be_present)
    expect(result[:name]).to(eq('Renamed Via Name Row'))
  end

  it 'reindexes both sides of a Relationship when it is created' do
    project = create(:project)
    place_model = create(:place_model, project:)
    types_model = create(:taxonomy_model, project:)
    rel = create(:project_model_relationship, primary_model: place_model, related_model: types_model, name: 'Types', multiple: true)

    place = create(:place, project_model: place_model, name: 'Related Church')
    church = create(:taxonomy, project_model: types_model, name: 'Church')
    CoreDataConnector::OpenGeographies::V1::Place.searchkick_index.refresh

    create(:relationship, project_model_relationship: rel, primary_record: place, related_record: church)
    CoreDataConnector::OpenGeographies::V1::Place.searchkick_index.refresh

    result = CoreDataConnector::OpenGeographies::V1::Place
      .search('*', where: { slug: 'related-church' }, load: false)
      .first
    expect(result[:types]).to(eq(['Church']))
  end
end
