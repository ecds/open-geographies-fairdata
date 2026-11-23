# frozen_string_literal: true

require 'rails_helper'

# Real Elasticsearch, not a mock - same rationale as place_indexing_spec.rb:
# the whole point of Reindexable is that a *real* Searchkick write happens
# automatically, with nothing in the test explicitly triggering it (unlike
# every other request/indexing spec in this suite, which calls
# `.reindex(refresh: true)` itself). Asserting against a mock would prove
# nothing about whether the after_commit callback actually fired.
RSpec.describe('V1 Reindexable') do
  after do
    index = OpenGeographies::V1::Place.searchkick_index
    index.delete if index.exists?
  end

  # A Place needs a primary PlaceName to pass Nameable#validate_names at its
  # OWN initial save - built before save!, not created afterward, same
  # constraint spec/factories/place.rb's own comment explains.
  def build_base_place(place_model, name)
    place = CoreDataConnector::Place.new(project_model: place_model, user_defined: {})
    place.place_names.build(name:, primary: true)
    place.save!
    place
  end

  it 'indexes a record created through the BASE class, not V1::, with no explicit reindex call' do
    project = create(:project)
    place_model = create(:place_model, project:)

    # CoreDataConnector::Place, not V1::Place - simulates FairData UI, which
    # has no reason to know the V1:: namespace exists. This is exactly the
    # save path Searchkick's own callback (registered only on V1::Place)
    # never sees.
    build_base_place(place_model, 'Base Class Church')

    OpenGeographies::V1::Place.searchkick_index.refresh

    result = OpenGeographies::V1::Place
      .search('*', where: { model_type: 'place', slug: 'base-class-church' }, load: false)
      .first

    expect(result).to(be_present)
    expect(result[:name]).to(eq('Base Class Church'))
  end

  it 'updates the indexed document when the base class record is updated' do
    project = create(:project)
    place_model = create(:place_model, project:)
    place = build_base_place(place_model, 'Original Name')

    OpenGeographies::V1::Place.searchkick_index.refresh

    place.place_names.first.update!(name: 'Renamed Church')
    OpenGeographies::V1::Place.searchkick_index.refresh

    result = OpenGeographies::V1::Place
      .search('*', where: { model_type: 'place', slug: 'renamed-church' }, load: false)
      .first

    expect(result).to(be_present)
    expect(result[:name]).to(eq('Renamed Church'))
  end

  it 'removes the document from the index when the base class record is destroyed' do
    project = create(:project)
    place_model = create(:place_model, project:)
    place = build_base_place(place_model, 'Doomed Church')

    OpenGeographies::V1::Place.searchkick_index.refresh
    expect(
      OpenGeographies::V1::Place.search('*', where: { slug: 'doomed-church' }, load: false).first,
    ).to(be_present)

    place.destroy!
    OpenGeographies::V1::Place.searchkick_index.refresh

    expect(
      OpenGeographies::V1::Place.search('*', where: { slug: 'doomed-church' }, load: false).first,
    ).to(be_nil)
  end

  it 'never indexes a record created with published: false' do
    # Publishable#set_published (before_validation on: :create) sets
    # `published` from the project's own default_to_published - it can't be
    # set directly on .new, only by controlling that default.
    project = create(:project, default_to_published: false)
    place_model = create(:place_model, project:)
    place = CoreDataConnector::Place.new(project_model: place_model, user_defined: {})
    place.place_names.build(name: 'Unpublished Church', primary: true)
    place.save!
    expect(place.published).to(eq(false))

    index = OpenGeographies::V1::Place.searchkick_index
    index.refresh if index.exists?
    result = index.exists? ? OpenGeographies::V1::Place.search('*', where: { slug: 'unpublished-church' }, load: false).first : nil

    expect(result).to(be_nil)
  end

  it 'removes an indexed record from the index when it is unpublished' do
    project = create(:project)
    place_model = create(:place_model, project:)
    place = build_base_place(place_model, 'Soon Unpublished Church')

    OpenGeographies::V1::Place.searchkick_index.refresh
    expect(
      OpenGeographies::V1::Place.search('*', where: { slug: 'soon-unpublished-church' }, load: false).first,
    ).to(be_present)

    place.update!(published: false)
    OpenGeographies::V1::Place.searchkick_index.refresh

    expect(
      OpenGeographies::V1::Place.search('*', where: { slug: 'soon-unpublished-church' }, load: false).first,
    ).to(be_nil)
  end

  it 'suspends indexing for the duration of .disable, with nothing indexed until a later manual reindex' do
    project = create(:project)
    place_model = create(:place_model, project:)

    OpenGeographies::V1::Reindexable.disable do
      build_base_place(place_model, 'Suspended Church')
    end

    index = OpenGeographies::V1::Place.searchkick_index
    index.refresh if index.exists?
    result = index.exists? ? OpenGeographies::V1::Place.search('*', where: { slug: 'suspended-church' }, load: false).first : nil
    expect(result).to(be_nil)

    # A subsequent, unrelated create outside the block still indexes
    # normally - .disable only suspends for its own duration, not globally
    # for the rest of the process.
    build_base_place(place_model, 'Unsuspended Church')
    OpenGeographies::V1::Place.searchkick_index.refresh

    expect(
      OpenGeographies::V1::Place.search('*', where: { slug: 'unsuspended-church' }, load: false).first,
    ).to(be_present)
  end
end
