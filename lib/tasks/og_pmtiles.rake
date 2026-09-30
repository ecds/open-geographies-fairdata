# frozen_string_literal: true

# lib/tasks/og_pmtiles.rake
#
# Generalized (any v1 atlas, not just Georgia Coast Atlas) PMTiles pipeline,
# replacing core-data-cloud's old ecds_pmtiles.rake's GCA-specific one:
# geometry + properties come from OpenGeographies::V1::Place.each_geojson_feature,
# so every atlas gets the same OG-schema-shaped properties (uuid/slug/name/
# model_type/project/types) for free, instead of a hand-maintained per-atlas
# property mapping. One flat vector-tile layer, not one layer per taxonomy
# type - `types` is just a property now, so a MapLibre client filters/styles
# by it (e.g. `["in", "Church", ["get", "types"]]`) instead of toggling
# separate tippecanoe layers.
#
# Lives in the engine, not the host app - this task has never needed
# anything core-data-cloud-specific (Tippecanoe::Builder is a standalone
# CLI wrapper with no Rails/CoreDataConnector coupling at all), so keeping
# it here means any FairData-backed host that mounts this engine gets PMTiles
# export for free too, rather than needing to copy the whole task over by
# hand. S3 bucket / CloudFront distribution stay runtime options with
# sensible defaults, not hardcoded to one deployment.
#
# Designed to run unattended (cron/whenever, a scheduled CI job, ...): every
# option has a default, nothing is interactive, and a failure raises/exits
# non-zero rather than silently producing a partial file.

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'aws-sdk-s3'
require 'aws-sdk-cloudfront'

namespace :og_pmtiles do
  desc "Build and publish a PMTiles file for a v1 atlas's places (generalized OG engine export, not GCA-specific)"
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

    # Written to two separate files, not one - see the tippecanoe build
    # step below for why. `contained_in` (see V1::Place.each_geojson_feature)
    # is exactly the same distinction a MapLibre client already uses to
    # tell a walked-in admin area apart from a place from --place-model.
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

    # Two separate tippecanoe invocations, merged with tile-join, not one
    # build with a single set of flags - --cluster-distance (and
    # --drop-densest-as-needed before it) is a whole-invocation setting
    # with no per-feature opt-out. Verified empirically: a feature pinned
    # to tippecanoe.minzoom:0 (see V1::Place#emit_admin_area_feature) still
    # gets merged into a cluster blob if it's fed into a build that has
    # --cluster-distance on at all, and routing it to its own
    # tippecanoe.layer only stops it from clustering *with* places - within
    # its own layer, all of it still clustered into one blob, losing every
    # individual name/admin_level. Places (potentially thousands, e.g.
    # Georgia Coast) should cluster; admin areas (a small, bounded set -
    # 29 for Georgia) must always render individually and by name, never
    # merged into a "N counties" bubble. tile-join combines the two
    # .mbtiles back into one final "places" layer, matching what every
    # existing client (the WP shortcode) already expects as a single
    # source-layer - a client tells a cluster apart from a real place via
    # tippecanoe's own `clustered`/`point_count` properties, the same way
    # it already tells an admin area apart via `contained_in`.
    # Reads a built .mbtiles' own maxzoom straight from its SQLite metadata
    # table (the mbtiles spec guarantees this key) - the ground truth for
    # what zoom range a tileset's tiles actually exist at, not the flags
    # that were passed to build it.
    read_mbtiles_maxzoom = lambda do |path|
      out, _err, status = Open3.capture3('sqlite3', path.to_s, "SELECT value FROM metadata WHERE name = 'maxzoom';")
      status.success? && !out.strip.empty? ? Integer(out.strip) : nil
    end

    builder = Tippecanoe::Builder.new({ layer: 'places' })
    mbtiles_to_merge = []

    # Tippecanoe::ExecutionError carries the failed command's own real
    # stdout/stderr (Tippecanoe::Builder#run_command captures both), but
    # by default nothing ever prints them - Rake's own "task aborted!"
    # handler only shows the exception's #message, e.g. "tippecanoe
    # failed (exit 104)", with no indication of WHY. Found live: that
    # alone gave no way to diagnose a real failure - every one of these
    # four tippecanoe/pmtiles invocations succeeded when reproduced
    # directly, immediately after, with the exact same input files and
    # flags, so whatever actually went wrong only exists in the output
    # this rescue makes sure is no longer thrown away.
    begin
      if place_count.positive?
        # --cluster-maxzoom=g: without it, tippecanoe keeps clustering active
        # all the way up through the tileset's own maxzoom, so two points
        # closer together than --cluster-distance at THAT zoom stay merged
        # forever - there's no deeper tile data for a viewer to zoom into
        # that would ever separate them. The
        # "g" magic value (matching -zg's own) sets the cluster cutoff to
        # maxzoom - 1 automatically, so every point is guaranteed to render
        # individually by the tileset's own max zoom, regardless of how
        # close two real places are - no manual per-atlas tuning needed.
        place_extra_args = ['-zg', '-r1', "--cluster-distance=#{options[:cluster_distance]}", '--cluster-maxzoom=g']
        # Tippecanoe::Builder#build_mbtiles (called directly here for
        # per-build flag control) does NOT delete a pre-existing output
        # file first - only the higher-level #build wrapper does that,
        # which this task stopped using once places/admin needed two
        # separate invocations. Without this, tippecanoe correctly refuses
        # to overwrite an existing tileset ("already exists... use
        # --force") - real failure hit live on a second run in the same
        # tmp_dir, exit 104, previously indistinguishable from a genuine
        # crash until the rescue below started surfacing tippecanoe's own
        # stderr.
        File.delete(places_mbtiles_path) if File.exist?(places_mbtiles_path)
        builder.build_mbtiles(input: places_geojson_path.to_s, output: places_mbtiles_path.to_s, extra_args: place_extra_args)
        mbtiles_to_merge << places_mbtiles_path
      end

      if admin_count.positive?
        # Matches the places tileset's own maxzoom explicitly (-zN), not -zg
        # independently guessing one for this dataset - real bug found live:
        # ~29 sparse admin-area features spread across a whole state give -zg
        # far less reason to go deep than hundreds of tightly-clustered place
        # points do (confirmed: -zg picked z1 for admin alone vs. z12 for
        # places in a synthetic reproduction of this atlas's real
        # proportions), so admin_areas.mbtiles simply had no tile data past
        # z1 at all - not a dropped-feature problem this time, an
        # out-of-range one. tile-join can't merge in tiles that were never
        # generated, so every admin feature vanished the moment a viewer
        # zoomed in past whatever shallow zoom -zg happened to pick for this
        # much sparser layer. No drop/cluster flags either way - nothing
        # this small should ever be thinned, and
        # V1::Place#emit_admin_area_feature's own per-feature
        # tippecanoe.minzoom:0 pin is already there as a second layer of
        # protection regardless. Falls back to -zg only when there's no
        # places tileset to keep pace with at all.
        admin_extra_args =
          if place_count.positive?
            places_maxzoom = read_mbtiles_maxzoom.call(places_mbtiles_path)
            raise "Could not read maxzoom from #{places_mbtiles_path} (needed so admin-area features cover the same zoom range as places and don't vanish while zooming in) - is the sqlite3 CLI installed?" unless places_maxzoom

            ["-z#{places_maxzoom}"]
          else
            ['-zg']
          end
        # Same reason as the places build above - build_mbtiles doesn't
        # clear a stale output file on its own.
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
      # Aws::S3::Object#upload_file is deprecated (removed in the next major
      # SDK version) in favor of TransferManager - same underlying client,
      # so it still raises Aws::S3::Errors::ServiceError on failure the same way.
      transfer_manager = Aws::S3::TransferManager.new(client: Aws::S3::Client.new(region: 'us-east-1'))
      transfer_manager.upload_file(pmtiles_path.to_s, bucket: options[:s3_bucket], key: options[:s3_key])
      puts 'Upload complete.'
    rescue Aws::S3::Errors::ServiceError => e
      raise "S3 upload failed: #{e.message}"
    end

    if options[:cloudfront_distribution_id]
      # Scoped to this atlas's own key, not '/*' - the bucket (default
      # ecds-pmtiles) holds every atlas's PMTiles file behind the same
      # distribution, so a wildcard invalidation would evict every other
      # atlas's already-warm cache (and cost more - CloudFront bills
      # invalidation paths, and '/*' is billed the same as a scoped one)
      # every time a single atlas republishes. The trailing '*' still
      # covers whatever the Lambda actually serves under this basename
      # (the TileJSON at "/<key>.json" and any tile sub-paths beneath it),
      # not just the literal .pmtiles object key.
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
        # Not fatal: the new file is already live on S3, just not cache-busted
        # everywhere yet - worth surfacing, not worth failing an otherwise-
        # successful publish over.
        puts "Warning: CloudFront invalidation failed: #{e.message}"
      end
    else
      puts 'No --distribution/CLOUDFRONT_DISTRIBUTION_ID given - skipping CDN invalidation.'
    end

    FileUtils.rm_rf(tmp_dir)
  end
end
