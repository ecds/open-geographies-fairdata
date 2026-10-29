# frozen_string_literal: true

require 'rails_helper'

# Uses real Elasticsearch indexes. Records are saved through the base classes,
# so writes go through Reindexable's callbacks as they do from the FairData UI.
RSpec.describe(OpenGeographies::V1::Indexes) do
  let(:indexes) { described_class }
  let(:layout) { 'per_project' }

  let(:project) { create(:project) }
  let(:place_model) { create(:place_model, project:) }

  around do |example|
    previous_layout = ENV.fetch('OG_INDEX_LAYOUT', nil)
    previous_adapter = ActiveJob::Base.queue_adapter
    ENV['OG_INDEX_LAYOUT'] = layout
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    previous_layout.nil? ? ENV.delete('OG_INDEX_LAYOUT') : ENV['OG_INDEX_LAYOUT'] = previous_layout
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  after do
    client = Searchkick.client
    client.indices.get(index: 'open_geographies_v1_project_*').each_key { |name| client.indices.delete(index: name) }
    shared = OpenGeographies::V1::Place.searchkick_index
    shared.delete if shared.exists?
  end

  # Names of the documents in a project's index.
  def names_in(project_id)
    index = indexes.project_index(project_id)
    index.refresh
    hits = Searchkick.client.search(index: index.name, body: { size: 100, query: { match_all: {} } })['hits']['hits']
    hits.map { |hit| hit['_source']['name'] }
  end

  # Physical indexes behind a project's alias.
  def aliased_indexes(project_id)
    Searchkick.client.indices.get_alias(name: indexes.project_index_name(project_id)).keys
  end

  def physical_indexes(project_id)
    Searchkick.client.indices.get(index: "#{indexes.project_index_name(project_id)}_*").keys
  end

  def shared_names
    shared = OpenGeographies::V1::Place.searchkick_index
    return [] unless shared.exists?

    shared.refresh
    Searchkick.client.search(index: shared.name, body: { size: 100, query: { match_all: {} } })['hits']['hits']
      .map { |hit| hit['_source']['name'] }
  end

  describe '.name_for' do
    context 'with the shared layout' do
      let(:layout) { 'shared' }

      it 'is the shared index' do
        expect(indexes.name_for(project.id)).to(eq('open_geographies_v1'))
      end
    end

    it "is the project's own index under per_project" do
      expect(indexes.name_for(project.id)).to(eq("open_geographies_v1_project_#{project.id}"))
    end

    context 'with an unknown layout' do
      let(:layout) { 'sideways' }

      it 'falls back to shared' do
        expect(indexes.layout).to(eq('shared'))
      end
    end
  end

  describe '.rebuild' do
    it "indexes every published record of the project's indexed classes, and nothing from other projects" do
      create(:place, project_model: place_model, name: 'Evergreen Church')
      create(:place, project_model: place_model, name: 'Hidden Church').update!(published: false)
      types_model = create(:taxonomy_model, project:)
      create(:taxonomy, project_model: types_model, name: 'Church')
      create(:place, project_model: create(:place_model, project: create(:project)), name: 'Elsewhere')

      result = indexes.rebuild(project.id)

      expect(names_in(project.id)).to(contain_exactly('Evergreen Church', 'Church'))
      expect(result[:documents]).to(eq(2))
      expect(result[:index]).to(match(/\Aopen_geographies_v1_project_#{project.id}_\d{14,17}\z/))
      expect(aliased_indexes(project.id)).to(eq([result[:index]]))
    end

    it 'moves the alias to a new index and deletes the old one' do
      create(:place, project_model: place_model, name: 'Evergreen Church')
      first = indexes.rebuild(project.id)[:index]

      second = indexes.rebuild(project.id)[:index]

      expect(second).not_to(eq(first))
      expect(aliased_indexes(project.id)).to(eq([second]))
      expect(physical_indexes(project.id)).to(eq([second]))
      expect(names_in(project.id)).to(eq(['Evergreen Church']))
    end

    it 'includes records created, renamed and destroyed while it runs' do
      renamed = create(:place, project_model: place_model, name: 'Old Name')
      doomed = create(:place, project_model: place_model, name: 'Doomed Church')
      changed = false

      indexes.rebuild(project.id) do |completed, _total|
        next if changed || completed.zero?

        changed = true
        renamed.place_names.first.update!(name: 'New Name')
        doomed.destroy!
        create(:place, project_model: place_model, name: 'Added Church')
      end

      expect(changed).to(be(true))
      expect(names_in(project.id)).to(contain_exactly('New Name', 'Added Church'))
      expect(OpenGeographies::IndexRebuild.count).to(eq(0))
    end

    it 'leaves the old index serving and deletes the new one when it fails before the swap' do
      create(:place, project_model: place_model, name: 'Evergreen Church')
      serving = indexes.rebuild(project.id)[:index]
      allow_any_instance_of(Searchkick::Index).to(receive(:promote).and_raise('promote failed'))

      expect { indexes.rebuild(project.id) }.to(raise_error('promote failed'))

      expect(aliased_indexes(project.id)).to(eq([serving]))
      expect(physical_indexes(project.id)).to(eq([serving]))
      expect(OpenGeographies::IndexRebuild.count).to(eq(0))
    end
  end

  describe 'per-record writes' do
    it "writes a saved record to its project's index and not to the shared index" do
      indexes.rebuild(project.id)

      create(:place, project_model: place_model, name: 'New Church')

      expect(names_in(project.id)).to(eq(['New Church']))
      expect(OpenGeographies::V1::Place.searchkick_index.exists?).to(be(false))
    end

    it 'queues a full build, and writes nothing, when the project has no index yet' do
      expect { create(:place, project_model: place_model, name: 'First Church') }
        .to(have_enqueued_job(OpenGeographies::V1::RebuildIndexJob).with(project.id).at_least(:once))

      expect(indexes.project_index(project.id).exists?).to(be(false))
    end

    it "removes a destroyed record from its project's index" do
      place = create(:place, project_model: place_model, name: 'Doomed Church')
      indexes.rebuild(project.id)

      place.destroy!

      expect(names_in(project.id)).to(be_empty)
    end

    it "removes an unpublished record from its project's index" do
      place = create(:place, project_model: place_model, name: 'Soon Unpublished Church')
      indexes.rebuild(project.id)

      place.update!(published: false)

      expect(names_in(project.id)).to(be_empty)
    end

    it "writes each side of a cross-project relationship to its own project's index" do
      other_project = create(:project)
      county_model = create(:place_model, project: other_project)
      place = create(:place, project_model: place_model, name: 'Evergreen Church')
      county = create(:place, project_model: county_model, name: 'Putnam County')
      indexes.rebuild(project.id)
      indexes.rebuild(other_project.id)

      rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Located In', multiple: false)
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: county)

      index = indexes.project_index(project.id)
      index.refresh
      church = Searchkick.client.search(index: index.name, body: { query: { term: { slug: 'evergreen-church' } } })['hits']['hits'].first
      expect(church['_source']['located_in']).to(include('name' => 'Putnam County'))
      expect(names_in(project.id)).to(eq(['Evergreen Church']))
      expect(names_in(other_project.id)).to(eq(['Putnam County']))
    end

    context 'with the both layout' do
      let(:layout) { 'both' }

      it "writes a saved record to the shared index and to the project's index" do
        indexes.rebuild(project.id)

        create(:place, project_model: place_model, name: 'New Church')

        expect(names_in(project.id)).to(eq(['New Church']))
        expect(shared_names).to(include('New Church'))
      end

      it "writes only to the shared index until the project's index is built" do
        create(:place, project_model: place_model, name: 'New Church')

        expect(shared_names).to(include('New Church'))
        expect(indexes.project_index(project.id).exists?).to(be(false))
        expect(OpenGeographies::V1::RebuildIndexJob).not_to(have_been_enqueued)
      end
    end
  end
end
