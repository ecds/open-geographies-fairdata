# frozen_string_literal: true

# lib/tasks/og_pmtiles.rake
#
# Builds a PMTiles file for any v1 atlas and optionally publishes it. Geometry
# and properties come from OpenGeographies::V1::Place.each_geojson_feature, so
# every atlas gets the same schema-shaped properties (uuid, slug, name,
# model_type, project, types) with no per-atlas property mapping. The output
# is one flat vector-tile layer; `types` is a property, so a MapLibre client
# filters and styles by it (e.g. `["in", "Park", ["get", "types"]]`) and does
# not need a separate layer per type.
#
# The task lives in the engine because nothing in it depends on a particular
# host app: Tippecanoe::Builder is a standalone CLI wrapper, so any FairData
# host that mounts this engine gets the export. The S3 bucket and CloudFront
# distribution are runtime options with defaults, not hardcoded.
#
# It is meant to run unattended (cron, a scheduled CI job): every option has a
# default, nothing is interactive, and a failure raises and exits non-zero
# instead of producing a partial file.

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'aws-sdk-s3'
require 'aws-sdk-cloudfront'

namespace :og_pmtiles do
  desc "Build and publish a PMTiles file for a v1 atlas's places"
  task create: :environment do
    options = {
      project: ENV['PROJECT'] || 'Georgia Coast Atlas',
      place_model: ENV['PLACE_MODEL'] || 'Places',
      s3_bucket: ENV['S3_BUCKET'] || 'ecds-pmtiles',
      s3_key: ENV['S3_KEY'],
      cloudfront_distribution_id: ENV['CLOUDFRONT_DISTRIBUTION_ID'],
      skip_upload: ENV['SKIP_UPLOAD'] == 'true',
      cluster_distance: (ENV['CLUSTER_DISTANCE'] || 25).to_i,
    }

    opt_parser = OptionParser.new do |opts|
      opts.banner = 'Usage: rake og_pmtiles:create -- [options]'

      opts.on('-p', '--project NAME', String, 'Project name (default: Georgia Coast Atlas).') { |v| options[:project] = v }
      opts.on('-m', '--place-model NAME', String, 'Place-class project model name within that project (default: Places).') { |v| options[:place_model] = v }
      opts.on('-b', '--bucket NAME', String, 'S3 bucket (default: ecds-pmtiles).') { |v| options[:s3_bucket] = v }
      opts.on('-k', '--key NAME', String, 'S3 object key (default: derived from the project name).') { |v| options[:s3_key] = v }
      opts.on('-d', '--distribution ID', String, 'CloudFront distribution id to invalidate after upload (skipped if omitted).') { |v| options[:cloudfront_distribution_id] = v }
      opts.on('-c', '--cluster-distance PIXELS', Integer, 'Pixel distance within which place points cluster together at low zoom (default: 25). Admin areas (counties/state) are never clustered or dropped.') { |v| options[:cluster_distance] = v }
      opts.on('-s', '--skip-upload', 'Build the PMTiles file locally only - skip S3 upload and CDN invalidation.') { options[:skip_upload] = true }
      opts.on('-h', '--help', 'Show this help message') do
        puts opts
        exit
      end
    end
    opt_parser.order!(ARGV.drop(1))

    options[:s3_key] ||= "#{options[:project].parameterize}.pmtiles"

    project = CoreDataConnector::Project.find_by!(name: options[:project])
    place_model = CoreDataConnector::ProjectModel.find_by!(project:, name: options[:place_model])

    tmp_dir = Rails.root.join('tmp', 'og_pmtiles')
    FileUtils.mkdir_p(tmp_dir)
    places_geojson_path = tmp_dir.join('places.geojson')
    admin_geojson_path = tmp_dir.join('admin_areas.geojson')
    places_mbtiles_path = tmp_dir.join('places.mbtiles')
    admin_mbtiles_path = tmp_dir.join('admin_areas.mbtiles')
    merged_mbtiles_path = tmp_dir.join('merged.mbtiles')
    pmtiles_path = tmp_dir.join(options[:s3_key])

    puts "Exporting #{place_model.name.inspect} places from #{project.name.inspect} (project_model_id=#{place_model.id})..."

    # Features are written to two files, one for the project model's own places
    # and one for the admin areas reached through Contained In, because they
    # are built separately below. `contained_in` (see
    # V1::Place.each_geojson_feature) marks the admin areas.
    place_count = 0
    admin_count = 0
    File.open(places_geojson_path, 'w') do |places_file|
      File.open(admin_geojson_path, 'w') do |admin_file|
        places_file.write('{"type":"FeatureCollection","features":[')
        admin_file.write('{"type":"FeatureCollection","features":[')
        place_first = true
        admin_first = true

        OpenGeographies::V1::Place.each_geojson_feature(place_model) do |feature|
          if feature[:properties][:contained_in]
            admin_file.write(',') unless admin_first
            admin_file.write(JSON.dump(feature))
            admin_first = false
            admin_count += 1
          else
            places_file.write(',') unless place_first
            places_file.write(JSON.dump(feature))
            place_first = false
            place_count += 1
          end
        end

        places_file.write(']}')
        admin_file.write(']}')
      end
    end
    raise "No features exported for #{options[:project].inspect} / #{options[:place_model].inspect} - aborting rather than publish an empty tileset." if (place_count + admin_count).zero?

    puts "#{place_count} place features, #{admin_count} admin-area features written."
    puts 'Building PMTiles with tippecanoe (places clustered, admin areas kept individually)...'

    # Two tippecanoe invocations are merged with tile-join, and not built in
    # one run, because --cluster-distance (like --drop-densest-as-needed) applies
    # to the whole invocation and cannot be turned off for individual features.
    # A feature with `tippecanoe.minzoom: 0` is still merged into a cluster
    # when it is part of a build that clusters, and a separate
    # `tippecanoe.layer` only stops it clustering with places, not with the
    # other admin areas. Places (potentially thousands) should cluster; admin
    # areas (a small set) must render individually and keep their names.
    # tile-join combines the two tilesets into one "places" layer. A client
    # tells a cluster from a place by tippecanoe's `clustered` / `point_count`
    # properties, and an admin area by `contained_in`.
    #
    # Reads a built .mbtiles file's maxzoom from its SQLite metadata table,
    # which is the zoom range the tiles actually cover and not just what the
    # build flags requested.
    read_mbtiles_maxzoom = lambda do |path|
      out, _err, status = Open3.capture3('sqlite3', path.to_s, "SELECT value FROM metadata WHERE name = 'maxzoom';")
      status.success? && !out.strip.empty? ? Integer(out.strip) : nil
    end

    builder = Tippecanoe::Builder.new({ layer: 'places' })
    mbtiles_to_merge = []

    # Tippecanoe::ExecutionError carries the failed command's stdout and
    # stderr. Rake only prints the exception message (e.g. "tippecanoe failed
    # (exit 104)"), so the rescue below prints the output to show why it failed.
    begin
      if place_count.positive?
        # --cluster-maxzoom=g: without it, clustering stays active through the
        # tileset's maxzoom, so two points closer together than
        # --cluster-distance at that zoom stay merged and there is no deeper
        # zoom at which they separate. "g" sets the cluster cutoff to
        # maxzoom - 1, so every point renders individually at the maximum zoom.
        place_extra_args = ['-zg', '-r1', "--cluster-distance=#{options[:cluster_distance]}", '--cluster-maxzoom=g']
        # Tippecanoe::Builder#build_mbtiles does not delete an existing output
        # file (only #build does), and tippecanoe refuses to overwrite an
        # existing tileset (exit 104), so a stale file from a previous run is
        # removed first.
        File.delete(places_mbtiles_path) if File.exist?(places_mbtiles_path)
        builder.build_mbtiles(input: places_geojson_path.to_s, output: places_mbtiles_path.to_s, extra_args: place_extra_args)
        mbtiles_to_merge << places_mbtiles_path
      end

      if admin_count.positive?
        # The admin tileset is built with the places tileset's maxzoom (-zN)
        # and not with -zg. A small, sparse set of features gives -zg little
        # reason to go deep, so the admin tiles would stop at a low zoom and
        # tile-join cannot merge in tiles that were never generated, making
        # the admin areas disappear when zooming in. No drop or cluster flags
        # are used, since a set this small should not be thinned. Falls back
        # to -zg when there is no places tileset to match.
        admin_extra_args =
          if place_count.positive?
            places_maxzoom = read_mbtiles_maxzoom.call(places_mbtiles_path)
            raise "Could not read maxzoom from #{places_mbtiles_path} (needed so admin-area features cover the same zoom range as places and don't vanish while zooming in) - is the sqlite3 CLI installed?" unless places_maxzoom

            ["-z#{places_maxzoom}"]
          else
            ['-zg']
          end
        # Removes a stale output file, as for the places build above.
        File.delete(admin_mbtiles_path) if File.exist?(admin_mbtiles_path)
        builder.build_mbtiles(input: admin_geojson_path.to_s, output: admin_mbtiles_path.to_s, extra_args: admin_extra_args)
        mbtiles_to_merge << admin_mbtiles_path
      end

      if mbtiles_to_merge.size > 1
        File.delete(merged_mbtiles_path) if File.exist?(merged_mbtiles_path)
        builder.pmtiles_merge(output: merged_mbtiles_path.to_s, input: mbtiles_to_merge.map(&:to_s).join(' '))
      else
        merged_mbtiles_path = mbtiles_to_merge.first
      end

      File.delete(pmtiles_path) if File.exist?(pmtiles_path)
      builder.run_pmtiles_convert(merged_mbtiles_path.to_s, pmtiles_path.to_s)
    rescue Tippecanoe::ExecutionError => e
      warn("Tippecanoe command failed (exit #{e.status&.exitstatus}):")
      warn('--- stdout ---')
      warn(e.stdout)
      warn('--- stderr ---')
      warn(e.stderr)
      raise
    end

    puts "PMTiles written to #{pmtiles_path}"

    if options[:skip_upload]
      puts 'Skipping upload and cleanup (--skip-upload).'
      next
    end

    puts "Uploading to s3://#{options[:s3_bucket]}/#{options[:s3_key]}..."
    begin
      # TransferManager replaces the deprecated Aws::S3::Object#upload_file. It
      # raises Aws::S3::Errors::ServiceError on failure in the same way.
      transfer_manager = Aws::S3::TransferManager.new(client: Aws::S3::Client.new(region: 'us-east-1'))
      transfer_manager.upload_file(pmtiles_path.to_s, bucket: options[:s3_bucket], key: options[:s3_key])
      puts 'Upload complete.'
    rescue Aws::S3::Errors::ServiceError => e
      raise "S3 upload failed: #{e.message}"
    end

    if options[:cloudfront_distribution_id]
      # The invalidation is limited to this atlas's key and not '/*', because
      # the bucket holds every atlas's PMTiles file behind one distribution and
      # a wildcard would clear the other atlases' cached files too. The trailing
      # '*' also covers what is served under the same basename (the TileJSON at
      # "/<key>.json" and tile sub-paths), not just the .pmtiles object.
      invalidation_path = "/#{options[:s3_key].sub(/\.pmtiles\z/, "")}*"
      puts "Invalidating CloudFront cache at #{invalidation_path}..."
      begin
        cf_client = Aws::CloudFront::Client.new(region: 'us-east-1')
        invalidation = cf_client.create_invalidation(
          distribution_id: options[:cloudfront_distribution_id],
          invalidation_batch: {
            paths: { quantity: 1, items: [invalidation_path] },
            caller_reference: Time.now.to_i.to_s,
          },
        )
        puts "Invalidation submitted: #{invalidation.invalidation.id}"
      rescue Aws::CloudFront::Errors::ServiceError => e
        # Not fatal: the new file is already on S3 and only the cache is stale.
        puts "Warning: CloudFront invalidation failed: #{e.message}"
      end
    else
      puts 'No --distribution/CLOUDFRONT_DISTRIBUTION_ID given - skipping CDN invalidation.'
    end

    FileUtils.rm_rf(tmp_dir)
  end
end
