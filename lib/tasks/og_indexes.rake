# frozen_string_literal: true

# One search index per project; see OpenGeographies::V1::Indexes.
#
# Moving from the shared open_geographies_v1 index without downtime:
#
#   1. Set OG_INDEX_LAYOUT=both and restart. Reads stay on the shared index;
#      writes also go to a project's index once it exists.
#   2. bin/rails og_indexes:build          (every project; PROJECT_IDS=1,2 for some)
#   3. bin/rails og_indexes:report         (every project has an index; counts match)
#   4. Set OG_INDEX_LAYOUT=per_project and restart. Reads and writes move.
#   5. bin/rails og_indexes:drop_shared CONFIRM=open_geographies_v1
#      (only once every web and worker process runs per_project)
#
# Rebuilding one project, which also drops fields no longer written:
#   bin/rails og_indexes:build PROJECT_IDS=45
#
# Deleting the indexes of deleted projects (report lists them):
#   bin/rails og_indexes:drop_orphans CONFIRM=yes

namespace :og_indexes do
  desc 'Build (or rebuild) each project\'s own search index and swap its alias. PROJECT_IDS=1,2 limits it.'
  task build: :environment do
    indexes = OpenGeographies::V1::Indexes

    if indexes.layout == 'shared'
      warn 'OG_INDEX_LAYOUT is shared: writes made while this runs go only to the shared index, ' \
        'so these indexes fall behind until the next build. Set OG_INDEX_LAYOUT=both first.'
    end

    ids = ENV['PROJECT_IDS'].present? ? ENV['PROJECT_IDS'].split(',').map { |id| Integer(id) } : indexes.project_ids

    ids.each do |project_id|
      started = Time.current
      result = indexes.rebuild(project_id)
      puts format(
        'project %<id>d  %<alias>s -> %<index>s  %<docs>d documents, %<fields>d fields, %<secs>.1f s',
        id: project_id,
        alias: indexes.project_index_name(project_id),
        index: result[:index],
        docs: result[:documents],
        fields: result[:fields],
        secs: Time.current - started,
      )
    end
  end

  desc 'Per-project indexes: documents and fields each, projects without one, and what the shared index still holds'
  task report: :environment do
    indexes = OpenGeographies::V1::Indexes
    client = Searchkick.client
    shared = OpenGeographies::V1::Place.searchkick_index.name

    puts "layout: #{indexes.layout}"

    shared_counts =
      if client.indices.exists(index: shared)
        aggs = client.search(index: shared, body: { size: 0, aggs: { p: { terms: { field: 'project_id', size: 10_000 } } } })
        aggs['aggregations']['p']['buckets'].to_h { |bucket| [bucket['key'].to_i, bucket['doc_count']] }
      end

    if shared_counts
      puts "#{shared}: #{shared_counts.values.sum} documents, #{indexes.field_count(shared)} fields"
    else
      puts "#{shared}: (none)"
    end

    missing = []

    indexes.project_ids.each do |project_id|
      index = indexes.project_index(project_id)

      unless index.exists?
        missing << project_id
        next
      end

      physical = client.indices.get_alias(name: index.name).keys.join(',')
      line = format(
        'project %<id>d  %<alias>s -> %<physical>s  %<docs>d documents, %<fields>d fields',
        id: project_id,
        alias: index.name,
        physical:,
        docs: index.total_docs,
        fields: indexes.field_count(index.name),
      )
      line += "  (shared index: #{shared_counts.fetch(project_id, 0)})" if shared_counts
      puts line
    end

    puts "projects without an index: #{missing.join(", ")}" if missing.any?

    # Indexes left by projects that no longer exist (deleting a project
    # removes its documents, not its index).
    base = OpenGeographies::V1::Place.searchkick_index.name
    existing = CoreDataConnector::Project.pluck(:id).to_set
    orphans = client.indices.get_alias(index: "#{base}_project_*").keys.filter_map do |physical|
      project_id = physical[/\A#{Regexp.escape(base)}_project_(\d+)_\d{14,17}\z/, 1]&.to_i
      physical if project_id && !existing.include?(project_id)
    end
    puts "indexes of deleted projects: #{orphans.join(", ")}" if orphans.any?

    # Rebuilds under way, or left by a process that died (the project's next
    # rebuild removes those).
    OpenGeographies::IndexRebuild.order(:created_at).each do |build|
      puts "rebuild of project #{build.project_id} into #{build.index_name} since #{build.created_at.iso8601}, " \
        "#{build.logged_changes.count} changes logged"
    end

    # Physical indexes neither an alias nor a rebuild names: left behind.
    building = OpenGeographies::IndexRebuild.pluck(:index_name)
    unaliased = client.indices.get_alias(index: "#{base}_project_*").filter_map do |physical, info|
      physical if info['aliases'].blank? && !orphans.include?(physical) && !building.include?(physical)
    end
    puts "unaliased indexes (not in use; the project's next rebuild deletes them): #{unaliased.join(", ")}" if unaliased.any?
  end

  desc 'Delete the shared index once every project reads from its own (OG_INDEX_LAYOUT=per_project, CONFIRM=<index name>)'
  task drop_shared: :environment do
    indexes = OpenGeographies::V1::Indexes
    shared = OpenGeographies::V1::Place.searchkick_index

    abort 'OG_INDEX_LAYOUT must be per_project: readers still use the shared index.' unless indexes.per_project?

    missing = indexes.project_ids.reject { |project_id| indexes.project_index(project_id).exists? }
    abort "Projects without their own index: #{missing.join(", ")} - run og_indexes:build first." if missing.any?

    # Each project's index must hold at least what the shared index holds for
    # it: an index that exists can still be one created before its project
    # was built.
    client = Searchkick.client
    if client.indices.exists(index: shared.name)
      aggs = client.search(index: shared.name, body: { size: 0, aggs: { p: { terms: { field: 'project_id', size: 10_000 } } } })
      behind = aggs['aggregations']['p']['buckets'].filter_map do |bucket|
        project_id = bucket['key'].to_i
        own = indexes.project_index(project_id)
        next unless indexes.project_ids.include?(project_id)

        own_count = own.exists? ? client.count(index: own.name)['count'] : 0
        "#{project_id} (#{own_count} of #{bucket["doc_count"]})" if own_count < bucket['doc_count']
      end
      abort "Project indexes behind the shared one: #{behind.join(", ")} - rebuild them (og_indexes:build PROJECT_IDS=...)." if behind.any?
    end

    abort "Set CONFIRM=#{shared.name} to delete it. Every web and worker process must already run OG_INDEX_LAYOUT=per_project " \
      '(a process still on shared or both would recreate it on its next write).' unless ENV['CONFIRM'] == shared.name

    shared.delete
    puts "deleted #{shared.name}"
  end

  desc 'Delete the indexes of projects that no longer exist (CONFIRM=yes)'
  task drop_orphans: :environment do
    client = Searchkick.client
    base = OpenGeographies::V1::Place.searchkick_index.name
    existing = CoreDataConnector::Project.pluck(:id).to_set
    orphans = client.indices.get_alias(index: "#{base}_project_*").keys.select do |physical|
      project_id = physical[/\A#{Regexp.escape(base)}_project_(\d+)_\d{14,17}\z/, 1]&.to_i
      project_id && !existing.include?(project_id)
    end

    if orphans.empty?
      puts 'no indexes of deleted projects'
    elsif ENV['CONFIRM'] == 'yes'
      orphans.each { |physical| client.indices.delete(index: physical) }
      puts "deleted #{orphans.join(", ")}"
    else
      puts "would delete #{orphans.join(", ")} - set CONFIRM=yes"
    end
  end
end
