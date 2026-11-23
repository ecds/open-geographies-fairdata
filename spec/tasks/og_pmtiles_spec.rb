# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# Builds real tiles with tippecanoe, tile-join and the pmtiles CLI, and reads
# the result's metadata. Skipped where those tools are not installed.
RSpec.describe('og_pmtiles rake task') do
  tools = ['tippecanoe', 'tile-join', 'pmtiles', 'sqlite3']
  missing = tools.reject { |tool| system("command -v #{tool} > /dev/null 2>&1") }

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('og_pmtiles:create')
  end

  around do |example|
    keys = ['PROJECT_ID', 'PLACE_MODEL', 'SKIP_UPLOAD', 'OUTPUT', 'CLUSTER_DISTANCE', 'CLUSTER_MAXZOOM', 'MAXZOOM', 'S3_KEY']
    previous = keys.index_with { |key| ENV.fetch(key, nil) }
    keys.each { |key| ENV.delete(key) }
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  let(:factory) { RGeo::Geographic.spherical_factory(srid: 4326) }
  let(:project) { create(:project) }
  let(:place_model) { create(:place_model, project:, name: 'Places') }

  def run_task(**env)
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    task = Rake::Task['og_pmtiles:create']
    task.reenable
    previous = $stdout
    $stdout = StringIO.new
    task.invoke
  ensure
    $stdout = previous
  end

  def metadata(path)
    out, err, status = Open3.capture3('pmtiles', 'show', path, '--metadata')
    raise err unless status.success?

    JSON.parse(out)
  end

  # Two churches in a county, which is reached through Contained In.
  def create_atlas
    county_model = create(:place_model, project:, name: 'Counties')
    county = create(:place, project_model: county_model, name: 'Grady County')
    square = factory.polygon(factory.linear_ring([
      factory.point(-84.4, 30.7),
      factory.point(-84.0, 30.7),
      factory.point(-84.0, 31.0),
      factory.point(-84.4, 31.0),
      factory.point(-84.4, 30.7),
    ]))
    create(:place_geometry, place: county, geometry: square)
    contained = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false)

    [[-84.2, 30.85], [-84.21, 30.86]].each_with_index do |(lon, lat), index|
      place = create(:place, project_model: place_model, name: "Church #{index + 1}")
      create(:place_geometry, place:, geometry: factory.point(lon, lat))
      create(:relationship, project_model_relationship: contained, primary_record: place, related_record: county)
    end
  end

  it 'requires a project id' do
    expect { run_task(SKIP_UPLOAD: 'true') }.to(raise_error(ArgumentError, /PROJECT_ID/))
  end

  it 'refuses a cluster maxzoom that is not below the maxzoom' do
    expect { run_task(PROJECT_ID: project.id, SKIP_UPLOAD: 'true', MAXZOOM: 8, CLUSTER_MAXZOOM: 8) }
      .to(raise_error(ArgumentError, /must be below maxzoom/))
  end

  context 'with the tile tools installed' do
    before { skip("needs #{missing.join(", ")}") if missing.any? }

    it 'writes one places layer, named for the project, clustered by default' do
      create_atlas
      output = File.join(@dir, 'atlas.pmtiles')

      run_task(PROJECT_ID: project.id, SKIP_UPLOAD: 'true', OUTPUT: output, MAXZOOM: 10)
      meta = metadata(output)

      expect(meta['vector_layers'].pluck('id')).to(eq(['places']))
      expect(meta['name']).to(eq(project.name))
      expect(meta['description']).to(eq("Places of #{project.name}"))
      expect(meta['maxzoom'].to_i).to(eq(10))
      expect(meta['generator_options']).to(include('--cluster-distance=25', '--cluster-maxzoom=g', '-z10'))
      expect(meta['vector_layers'].first['fields'].keys).to(include('uuid', 'slug', 'name', 'types', 'contained_in'))
    end

    it 'leaves out clustering when the cluster distance is 0' do
      create_atlas
      output = File.join(@dir, 'atlas.pmtiles')

      run_task(PROJECT_ID: project.id, SKIP_UPLOAD: 'true', OUTPUT: output, CLUSTER_DISTANCE: 0, MAXZOOM: 10)

      expect(metadata(output)['generator_options']).not_to(include('--cluster'))
    end
  end
end
