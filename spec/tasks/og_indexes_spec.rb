# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# Runs the og_indexes rake tasks against real Elasticsearch indexes. The
# seeded projects (spec/seeds.rb) have places, so they count as projects here
# too.
RSpec.describe('og_indexes rake tasks') do
  let(:indexes) { OpenGeographies::V1::Indexes }
  let(:shared) { OpenGeographies::V1::Place.searchkick_index }
  let(:client) { Searchkick.client }
  let(:layout) { 'per_project' }

  let(:project) { create(:project) }
  let(:place_model) { create(:place_model, project:) }

  # Rake runs a task only once per process, and loading the tasks twice would
  # register every task body twice.
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('og_indexes:build')
  end

  around do |example|
    keys = ['OG_INDEX_LAYOUT', 'PROJECT_IDS', 'CONFIRM']
    previous = keys.index_with { |key| ENV.fetch(key, nil) }
    previous_adapter = ActiveJob::Base.queue_adapter
    ENV['OG_INDEX_LAYOUT'] = layout
    ENV.delete('PROJECT_IDS')
    ENV.delete('CONFIRM')
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  # spec/seeds.rb saves its places under the default shared layout, so the
  # shared index starts out holding them until some example deletes it.
  # Starting every example without it keeps the counts here independent of
  # the order the examples run in.
  before { shared.delete if shared.exists? }

  after do
    client.indices.get(index: 'open_geographies_v1_project_*').each_key { |name| client.indices.delete(index: name) }
    shared.delete if shared.exists?
  end

  def run_task(name, **env)
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    task = Rake::Task["og_indexes:#{name}"]
    task.reenable
    task.invoke
  end

  def capture_stdout
    previous = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = previous
  end

  # Saves a place under the shared layout, so it is written to the shared
  # index only, as before the move to per-project indexes.
  def create_shared_place(name)
    ENV['OG_INDEX_LAYOUT'] = 'shared'
    create(:place, project_model: place_model, name:)
    shared.refresh
  ensure
    ENV['OG_INDEX_LAYOUT'] = layout
  end

  # Gives a project an empty index of its own behind its alias.
  def create_empty_index(project_id)
    index = indexes.project_index(project_id)
    index.promote(index.create_index.name)
  end

  # Creates a physical index named the way a rebuild names one, with no alias.
  def create_physical_index(project_id)
    name = "#{indexes.project_index_name(project_id)}_#{Time.current.strftime("%Y%m%d%H%M%S%L")}"
    client.indices.create(index: name)
    name
  end

  def index_exists?(name)
    client.indices.exists(index: name)
  end

  def names_in(project_id)
    index = indexes.project_index(project_id)
    index.refresh
    client.search(index: index.name, body: { size: 100, query: { match_all: {} } })['hits']['hits']
      .map { |hit| hit['_source']['name'] }
  end

  def aliased_indexes(project_id)
    client.indices.get_alias(name: indexes.project_index_name(project_id)).keys
  end

  describe 'og_indexes:drop_shared' do
    # Where the move stands before this task runs: the shared index holds the
    # project's place, and every project has an index of its own that holds
    # at least as much.
    before do
      create_shared_place('Evergreen Church')
      indexes.rebuild(project.id)
      (indexes.project_ids - [project.id]).each { |project_id| create_empty_index(project_id) }
    end

    # Every guard test sets the right CONFIRM unless it is testing CONFIRM, so
    # only the guard under test can stop the task.
    def expect_abort(message, **env)
      expect { run_task('drop_shared', **env) }.to(raise_error(SystemExit, message).and(output.to_stderr))
      expect(shared.exists?).to(be(true))
    end

    ['shared', 'both'].each do |other_layout|
      it "aborts under the #{other_layout} layout" do
        expect_abort(/must be per_project/, OG_INDEX_LAYOUT: other_layout, CONFIRM: shared.name)
      end
    end

    it 'aborts when a project with places has no index of its own' do
      indexes.project_index(project.id).delete

      expect_abort(/Projects without their own index: #{project.id} -/, CONFIRM: shared.name)
    end

    it "aborts when a project's index holds fewer documents than the shared index has for it" do
      create_shared_place('Late Church')

      expect_abort(/Project indexes behind the shared one: #{project.id} \(1 of 2\)/, CONFIRM: shared.name)
    end

    it 'aborts without CONFIRM' do
      expect_abort(/Set CONFIRM=open_geographies_v1 to delete it/)
    end

    it 'aborts when CONFIRM is not the shared index name' do
      expect_abort(/Set CONFIRM=open_geographies_v1 to delete it/, CONFIRM: 'yes')
    end

    it 'deletes the shared index, and leaves the project indexes alone, when every guard passes' do
      project_indexes = client.indices.get(index: 'open_geographies_v1_project_*').keys

      expect { run_task('drop_shared', CONFIRM: shared.name) }.to(output("deleted open_geographies_v1\n").to_stdout)

      expect(shared.exists?).to(be(false))
      expect(client.indices.get(index: 'open_geographies_v1_project_*').keys).to(match_array(project_indexes))
      expect(names_in(project.id)).to(eq(['Evergreen Church']))
    end

    # Running the last step of the move a second time should not fail.
    it 'says so, and does not raise, when the shared index is already gone' do
      shared.delete

      expect { run_task('drop_shared', CONFIRM: shared.name) }
        .to(output("open_geographies_v1 does not exist; nothing to delete\n").to_stdout)
      expect(names_in(project.id)).to(eq(['Evergreen Church']))
    end
  end

  describe 'og_indexes:drop_orphans' do
    # The orphan's id is a prefix of the live project's, and the second
    # orphan's id starts with the live project's, so a match on a prefix of
    # the index name would pick the wrong one.
    let(:live) { create(:project, id: 900_012) }
    let(:orphan_id) { 90_001 }
    let(:other_orphan_id) { 9_000_120 }

    it 'reports that there is nothing to delete when no index belongs to a deleted project' do
      live_index = create_physical_index(live.id)

      expect { run_task('drop_orphans') }.to(output("no indexes of deleted projects\n").to_stdout)
      expect(index_exists?(live_index)).to(be(true))
    end

    it 'only lists the orphans without CONFIRM=yes' do
      live_index = create_physical_index(live.id)
      orphan = create_physical_index(orphan_id)

      expect { run_task('drop_orphans') }.to(output("would delete #{orphan} - set CONFIRM=yes\n").to_stdout)
      expect(index_exists?(orphan)).to(be(true))
      expect(index_exists?(live_index)).to(be(true))
    end

    it "deletes only the orphans with CONFIRM=yes, even when a live project's id looks alike" do
      live_index = create_physical_index(live.id)
      orphans = [create_physical_index(orphan_id), create_physical_index(other_orphan_id)]

      output = capture_stdout { run_task('drop_orphans', CONFIRM: 'yes') }

      expect(output).to(start_with('deleted '))
      expect(output.strip.delete_prefix('deleted ').split(', ')).to(match_array(orphans))
      orphans.each { |orphan| expect(index_exists?(orphan)).to(be(false)) }
      expect(index_exists?(live_index)).to(be(true))
    end
  end

  describe 'og_indexes:build' do
    let(:other_project) { create(:project) }
    let(:skipped_project) { create(:project) }

    before do
      create(:place, project_model: place_model, name: 'Evergreen Church')
      create(:place, project_model: create(:place_model, project: other_project), name: 'Putnam Church')
      create(:place, project_model: create(:place_model, project: skipped_project), name: 'Skipped Church')
    end

    it 'builds only the PROJECT_IDS projects, each with its alias on the new index' do
      output = capture_stdout { run_task('build', PROJECT_IDS: "#{project.id},#{other_project.id}") }

      [project, other_project].each do |built|
        physical = aliased_indexes(built.id)
        expect(physical.size).to(eq(1))
        expect(physical.first).to(match(/\Aopen_geographies_v1_project_#{built.id}_\d{14,17}\z/))
        expect(output).to(include("project #{built.id}  open_geographies_v1_project_#{built.id} -> #{physical.first}  1 documents"))
      end
      expect(names_in(project.id)).to(eq(['Evergreen Church']))
      expect(names_in(other_project.id)).to(eq(['Putnam Church']))
      expect(indexes.project_index(skipped_project.id).exists?).to(be(false))
    end

    it 'builds every project that has places without PROJECT_IDS' do
      capture_stdout { run_task('build') }

      expect(indexes.project_ids).to(include(project.id, other_project.id, skipped_project.id))
      indexes.project_ids.each { |project_id| expect(indexes.project_index(project_id).exists?).to(be(true)) }
    end

    context 'with the shared layout' do
      let(:layout) { 'shared' }

      it 'warns but still builds' do
        expect { run_task('build', PROJECT_IDS: project.id) }
          .to(output(/OG_INDEX_LAYOUT is shared/).to_stderr.and(output(/project #{project.id} /).to_stdout))

        expect(names_in(project.id)).to(eq(['Evergreen Church']))
      end
    end

    it 'fails on a non-numeric PROJECT_IDS before building anything' do
      expect { run_task('build', PROJECT_IDS: "#{project.id},abc") }.to(raise_error(ArgumentError, /"abc"/))

      expect(indexes.project_index(project.id).exists?).to(be(false))
    end
  end

  describe 'og_indexes:report' do
    let(:unbuilt_project) { create(:project) }

    before do
      create_shared_place('Evergreen Church')
      indexes.rebuild(project.id)
      create(:place, project_model: create(:place_model, project: unbuilt_project), name: 'Unbuilt Church')
    end

    it "prints the layout, each project's counts and the projects without an index" do
      output = capture_stdout { run_task('report') }

      expect(output).to(include("layout: per_project\n"))
      expect(output).to(include('open_geographies_v1: 1 documents'))
      expect(output).to(match(/^project #{project.id}  open_geographies_v1_project_#{project.id} -> \S+  1 documents, \d+ fields  \(shared index: 1\)$/))
      expect(output).to(match(/^projects without an index: .*\b#{unbuilt_project.id}\b/))
    end

    it 'lists the indexes of deleted projects' do
      orphan = create_physical_index(90_001)

      output = capture_stdout { run_task('report') }

      expect(output).to(include("indexes of deleted projects: #{orphan}\n"))
    end
  end
end
