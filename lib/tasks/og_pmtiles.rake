# frozen_string_literal: true

# lib/tasks/og_pmtiles.rake
#
# Builds a PMTiles file for any v1 atlas and optionally publishes it. Geometry
# and properties come from OpenGeographies::V1::Place.each_geojson_feature, so
# every atlas gets the same properties (see "Vector tiles" in the README) with
# no per-atlas property mapping. The output is one vector-tile layer named
# `places`. Tippecanoe writes array properties as JSON text, so `types` is a
# string such as '["Church","Park"]' and a style matches a type with its
# quotes: `["in", "\"Park\"", ["get", "types"]]`.
#
# The task lives in the engine because nothing in it depends on a particular
# host app: Tippecanoe::Builder is a standalone CLI wrapper, so any FairData
# host that mounts this engine gets the export. The S3 bucket and CloudFront
# distribution are runtime options with defaults, not hardcoded.
#
# It is meant to run unattended (cron, a scheduled CI job): only the project
# is required, nothing is interactive, each run builds in its own temporary
# directory, and a failure raises and exits non-zero instead of producing a
# partial file.

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require 'aws-sdk-s3'
require 'aws-sdk-cloudfront'

namespace :og_pmtiles do
  desc "Build and publish a PMTiles file for a v1 atlas's places (PROJECT_ID is required)"
  task create: :environment do
    # A zoom option is a whole number, or "g" to let tippecanoe choose.
    zoom_value = lambda do |value, name|
      text = value.to_s.strip
      next 'g' if text == 'g'

      Integer(text)
    rescue ArgumentError
      raise ArgumentError, "#{name} must be a whole number or \"g\", not #{value.inspect}"
    end

    options = {
      project_id: ENV['PROJECT_ID'],
      place_model: ENV['PLACE_MODEL'] || 'Places',
      s3_bucket: ENV['S3_BUCKET'] || 'ecds-pmtiles',
      s3_key: ENV['S3_KEY'],
      cloudfront_distribution_id: ENV['CLOUDFRONT_DISTRIBUTION_ID'],
      skip_upload: ENV['SKIP_UPLOAD'] == 'true',
      output: ENV['OUTPUT'],
      cluster_distance: Integer(ENV['CLUSTER_DISTANCE'] || 25),
      cluster_maxzoom: ENV['CLUSTER_MAXZOOM'] || 'g',
      maxzoom: ENV['MAXZOOM'] || 'g',
    }

    opt_parser = OptionParser.new do |opts|
      opts.banner = 'Usage: rake og_pmtiles:create -- --project-id ID [options]'

      opts.on('-p', '--project-id ID', String, 'Id of the atlas\'s project (required).') { |v| options[:project_id] = v }
      opts.on('-m', '--place-model NAME', String, 'Place-class project model name within that project (default: Places).') { |v| options[:place_model] = v }
      opts.on('-b', '--bucket NAME', String, 'S3 bucket (default: ecds-pmtiles).') { |v| options[:s3_bucket] = v }
      opts.on('-k', '--key NAME', String, 'S3 object key (default: the atlas\'s slug, as in the v1 API, plus .pmtiles).') { |v| options[:s3_key] = v }
      opts.on('-d', '--distribution ID', String, 'CloudFront distribution id to invalidate after upload (skipped if omitted).') { |v| options[:cloudfront_distribution_id] = v }
      opts.on('-c', '--cluster-distance PIXELS', Integer, 'Pixel distance within which place points cluster together at low zoom (default: 25; 0 turns clustering off). Admin areas are never clustered or dropped.') { |v| options[:cluster_distance] = v }
      opts.on('--cluster-maxzoom ZOOM', String, 'Last zoom at which places cluster (default: g, one below the deepest zoom).') { |v| options[:cluster_maxzoom] = v }
      opts.on('-z', '--maxzoom ZOOM', String, 'Deepest zoom to build (default: g, chosen by tippecanoe from how close the places are).') { |v| options[:maxzoom] = v }
      opts.on('-o', '--output PATH', String, 'Also keep the finished file here (default with --skip-upload: tmp/og_pmtiles/<key>).') { |v| options[:output] = v }
      opts.on('-s', '--skip-upload', 'Build the PMTiles file locally only - skip S3 upload and CDN invalidation.') { options[:skip_upload] = true }
      opts.on('-h', '--help', 'Show this help message') do
        puts opts
        exit
      end
    end
    # Options follow `--`. `rake` leaves the task name in ARGV before it and
    # `bin/rails` does not, so only what comes after `--` is parsed.
    separator = ARGV.index('--')
    opt_parser.parse!(separator ? ARGV[(separator + 1)..] : [])

    raise ArgumentError, "PROJECT_ID (or --project-id) is required.\n#{opt_parser}" if options[:project_id].blank?
    raise ArgumentError, 'cluster distance must be 0 or more' if options[:cluster_distance].negative?

    maxzoom = zoom_value.call(options[:maxzoom], 'maxzoom')
    cluster_maxzoom = zoom_value.call(options[:cluster_maxzoom], 'cluster maxzoom')
    if maxzoom.is_a?(Integer) && cluster_maxzoom.is_a?(Integer) && cluster_maxzoom >= maxzoom
      raise ArgumentError, "cluster maxzoom (#{cluster_maxzoom}) must be below maxzoom (#{maxzoom}), or places never separate"
    end

    project = CoreDataConnector::Project.find(options[:project_id])
    place_model = CoreDataConnector::ProjectModel.find_by!(project:, name: options[:place_model])
    options[:s3_key] ||= "#{project.name.parameterize}.pmtiles"
    options[:output] ||= Rails.root.join('tmp', 'og_pmtiles', options[:s3_key]).to_s if options[:skip_upload]

    # The name and description are stored in the file's metadata. Without
    # them, tippecanoe records the input file paths instead.
    name = project.name
    description = "Places of #{project.name}"

    Dir.mktmpdir('og_pmtiles') do |dir|
      tmp_dir = Pathname.new(dir)
      places_geojson_path = tmp_dir.join('places.geojson')
      admin_geojson_path = tmp_dir.join('admin_areas.geojson')
      places_mbtiles_path = tmp_dir.join('places.mbtiles')
      admin_mbtiles_path = tmp_dir.join('admin_areas.mbtiles')
      merged_mbtiles_path = tmp_dir.join('merged.mbtiles')
      pmtiles_path = tmp_dir.join(options[:s3_key])

      puts "Exporting #{place_model.name.inspect} places from #{project.name.inspect} (project_id=#{project.id}, project_model_id=#{place_model.id})..."

      # Features are written to two files, one for the project model's own
      # places and one for the admin areas reached through Contained In,
      # because they are built separately below. `contained_in` (see
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
      raise "No features exported for project #{project.id} / #{options[:place_model].inspect} - aborting rather than publish an empty tileset." if (place_count + admin_count).zero?

      puts "#{place_count} place features, #{admin_count} admin-area features written."
      clustering = options[:cluster_distance].positive?
      puts "Building PMTiles with tippecanoe (places #{clustering ? "clustered within #{options[:cluster_distance]}px" : "not clustered"}, admin areas kept individually)..."

      # Two tippecanoe invocations are merged with tile-join, and not built in
      # one run, because --cluster-distance (like --drop-densest-as-needed)
      # applies to the whole invocation and cannot be turned off for individual
      # features. A feature with `tippecanoe.minzoom: 0` is still merged into a
      # cluster when it is part of a build that clusters, and a separate
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

      builder = Tippecanoe::Builder.new({ layer: 'places', name:, description: })
      mbtiles_to_merge = []

      # Tippecanoe::ExecutionError carries the failed command's stdout and
      # stderr. Rake only prints the exception message (e.g. "tippecanoe failed
      # (exit 104)"), so the rescue below prints the output to show why it
      # failed.
      begin
        if place_count.positive?
          # -r1 keeps every point at every zoom instead of thinning them by
          # zoom level; clustering is what reduces them at low zooms. Without
          # clustering, a dense atlas can make tiles too large for tippecanoe.
          #
          # --cluster-maxzoom=g: without it, clustering stays active through
          # the tileset's maxzoom, so two points closer together than
          # --cluster-distance at that zoom stay merged and there is no deeper
          # zoom at which they separate. "g" sets the cluster cutoff to
          # maxzoom - 1, so every point renders individually at the maximum
          # zoom.
          place_extra_args = ["-z#{maxzoom}", '-r1']
          if clustering
            place_extra_args += ["--cluster-distance=#{options[:cluster_distance]}", "--cluster-maxzoom=#{cluster_maxzoom}"]
          end
          builder.build_mbtiles(input: places_geojson_path.to_s, output: places_mbtiles_path.to_s, extra_args: place_extra_args)
          mbtiles_to_merge << places_mbtiles_path
        end

        if admin_count.positive?
          # The admin tileset is built with the places tileset's maxzoom (-zN)
          # and not with -zg. A small, sparse set of features gives -zg little
          # reason to go deep, so the admin tiles would stop at a low zoom and
          # tile-join cannot merge in tiles that were never generated, making
          # the admin areas disappear when zooming in. No drop or cluster
          # flags are used, since a set this small should not be thinned.
          # Without a places tileset, the requested maxzoom is used.
          admin_extra_args =
            if place_count.positive?
              places_maxzoom = read_mbtiles_maxzoom.call(places_mbtiles_path)
              raise "Could not read maxzoom from #{places_mbtiles_path} (needed so admin-area features cover the same zoom range as places and don't vanish while zooming in) - is the sqlite3 CLI installed?" unless places_maxzoom

              ["-z#{places_maxzoom}"]
            else
              ["-z#{maxzoom}"]
            end
          builder.build_mbtiles(input: admin_geojson_path.to_s, output: admin_mbtiles_path.to_s, extra_args: admin_extra_args)
          mbtiles_to_merge << admin_mbtiles_path
        end

        if mbtiles_to_merge.size > 1
          builder.pmtiles_merge(
            output: merged_mbtiles_path.to_s,
            input: mbtiles_to_merge.map(&:to_s),
            extra_args: ['--name', name, '--description', description],
          )
        else
          merged_mbtiles_path = mbtiles_to_merge.first
        end

        builder.run_pmtiles_convert(merged_mbtiles_path.to_s, pmtiles_path.to_s)
      rescue Tippecanoe::ExecutionError => e
        warn("Tippecanoe command failed (exit #{e.status&.exitstatus}):")
        warn('--- stdout ---')
        warn(e.stdout)
        warn('--- stderr ---')
        warn(e.stderr)
        raise
      end

      if options[:output]
        FileUtils.mkdir_p(File.dirname(options[:output]))
        FileUtils.cp(pmtiles_path, options[:output])
        puts "PMTiles written to #{options[:output]}"
      end

      if options[:skip_upload]
        puts 'Skipping upload (--skip-upload).'
        next
      end

      puts "Uploading to s3://#{options[:s3_bucket]}/#{options[:s3_key]}..."
      begin
        # TransferManager replaces the deprecated Aws::S3::Object#upload_file.
        # It raises Aws::S3::Errors::ServiceError on failure in the same way.
        transfer_manager = Aws::S3::TransferManager.new(client: Aws::S3::Client.new(region: 'us-east-1'))
        transfer_manager.upload_file(pmtiles_path.to_s, bucket: options[:s3_bucket], key: options[:s3_key])
        puts 'Upload complete.'
      rescue Aws::S3::Errors::ServiceError => e
        raise "S3 upload failed: #{e.message}"
      end

      if options[:cloudfront_distribution_id]
        # The invalidation is limited to this atlas's key and not '/*',
        # because the bucket holds every atlas's PMTiles file behind one
        # distribution and a wildcard would clear the other atlases' cached
        # files too. The trailing '*' also covers what is served under the
        # same basename (the TileJSON at "/<key>.json" and tile sub-paths), not
        # just the .pmtiles object.
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
          # Not fatal: the new file is already on S3 and only the cache is
          # stale.
          puts "Warning: CloudFront invalidation failed: #{e.message}"
        end
      else
        puts 'No --distribution/CLOUDFRONT_DISTRIBUTION_ID given - skipping CDN invalidation.'
      end
    end
  end
end
