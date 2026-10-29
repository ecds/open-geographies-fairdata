# frozen_string_literal: true

module OpenGeographies
  module V1
    # Which Elasticsearch index a project's documents live in, and how that
    # index is built and rebuilt.
    #
    # A project's index is named '<shared name>_project_<project id>'
    # ('open_geographies_v1_project_45'). It uses the id and not the name
    # because a project can be renamed. That name is an alias over a physical
    # index named '<alias>_<timestamp>', Searchkick's convention, so its
    # promote and clean_indices helpers work unchanged. A rebuild fills a new
    # physical index while the old one keeps serving, then moves the alias in
    # one call. Readers never see an empty or partial index, a failed rebuild
    # leaves the old index serving, and fields no longer written are dropped.
    #
    # During a rebuild every per-record write goes to the alias and to the
    # index being built (named in an IndexRebuild row), and is logged in
    # IndexRebuildChange. Before the swap every logged record is read again
    # from the database and written to (or deleted from) the new index, until
    # a pass finds nothing new. The last pass and the swap hold WRITE_LOCK
    # exclusively, and writers take it shared, so nothing lands between them.
    #
    # OG_INDEX_LAYOUT chooses where reads and writes go:
    #   shared       - (default) one index for every project.
    #   both         - reads use the shared index; writes also go to the
    #                  project's index once it exists. Used while running
    #                  `og_indexes:build` to move off the shared index.
    #   per_project  - reads and writes use the project's index only.
    #
    # Map layers are not covered and keep their own index.
    module Indexes
      LAYOUTS = ['shared', 'both', 'per_project'].freeze

      # The classes whose documents live in a project's main index.
      CLASS_NAMES = Decorators::REINDEXED_MODELS

      # Postgres advisory lock keys, paired with the project id:
      #   BUILD_LOCK ("OI") - one build or rebuild of a project's index at a time.
      #   WRITE_LOCK ("OW") - writers hold it shared while writing a project's
      #     records; a rebuild holds it exclusively for its last replay and the
      #     alias swap.
      BUILD_LOCK = 0x4F49
      WRITE_LOCK = 0x4F57

      BATCH_SIZE = 500

      # Replay passes before the locked last one. Each pass writes what was
      # logged during the one before.
      REPLAY_PASSES = 10

      class << self
        def layout
          value = ENV.fetch('OG_INDEX_LAYOUT', 'shared')
          LAYOUTS.include?(value) ? value : 'shared'
        end

        def per_project?
          layout == 'per_project'
        end

        # The index (alias) to search for a project: its own under
        # per_project, otherwise the shared one.
        def name_for(project_id, klass = Place)
          per_project? ? project_index_name(project_id, klass) : klass.searchkick_index.name
        end

        def project_index_name(project_id, klass = Place)
          "#{klass.searchkick_index.name}_project_#{Integer(project_id)}"
        end

        # Searchkick::Index for a project's alias, with klass's mapping and settings.
        def project_index(project_id, klass = Place)
          klass.searchkick_index(name: project_index_name(project_id, klass))
        end

        # Writes or removes one record, choosing as Searchkick's #reindex does
        # (persisted?, destroyed?, should_index?). `record` is a V1 instance.
        # `project_id` is passed for a record destroyed with its project model,
        # which has no project left to look up.
        def store(record, project_id: nil)
          project_id ||= record.project_model&.project_id
          return remove_everywhere(record) unless project_id

          with_write_lock(project_id) { write([record], record.class, project_id) }
        end

        # Writes some of a project's records to wherever the layout writes,
        # without a rebuild. Under per_project, a project with no index yet is
        # rebuilt in full instead, so its index never holds only these records.
        def import(project_id, relation)
          if per_project? && !project_index(project_id, relation.klass).exists?
            return rebuild(project_id)
          end

          with_write_lock(project_id) do
            relation.find_in_batches(batch_size: BATCH_SIZE) { |batch| write(batch, relation.klass, project_id) }
          end

          nil
        end

        # Rebuilds one project's index: every published record of every
        # indexed class into a new physical index, records written meanwhile
        # replayed, then the alias moved and the old index deleted. Yields
        # (completed, total) after each batch. Returns { index:, documents:, fields: }.
        #
        # A rebuild that fails before the swap deletes its new index and leaves
        # the old one serving. One whose process is killed leaves its
        # IndexRebuild row and index behind until the project's next rebuild
        # removes them; og_indexes:report lists them.
        def rebuild(project_id, &progress)
          # The query cache is off so replays see what other connections wrote
          # during the fill.
          ActiveRecord::Base.uncached { rebuild_uncached(project_id, &progress) }
        end

        # The project's index, created if missing. It is created empty only
        # for a project with nothing to index; otherwise it is built in full.
        def ensure!(project_id, klass = Place)
          index = project_index(project_id, klass)
          return index if index.exists?

          if indexable_records?(project_id)
            ensure_built!(project_id)
          else
            with_build_lock(project_id) do
              unless index.exists?
                fresh = index.create_index
                index.promote(fresh.name)
              end
            end
          end

          index
        end

        # Builds the project's index unless it exists.
        def ensure_built!(project_id)
          with_build_lock(project_id) do
            rebuild(project_id) unless project_index(project_id).exists?
          end
        end

        # Fields counted against index.mapping.total_fields.limit (objects,
        # leaf fields and multi-fields).
        def field_count(index_name)
          mappings = Searchkick.client.indices.get_mapping(index: index_name).values.first['mappings']
          count_fields(mappings['properties'] || {})
        end

        # Every project with at least one model that a project index holds.
        def project_ids
          ::CoreDataConnector::ProjectModel.where(model_class: CLASS_NAMES.map { |name| "CoreDataConnector::#{name}" })
            .distinct.order(:project_id).pluck(:project_id)
        end

        private

        def rebuild_uncached(project_id, &progress)
          with_build_lock(project_id) do
            abandon_rebuilds!(project_id)

            alias_index = project_index(project_id)
            fresh = alias_index.create_index
            build = ::OpenGeographies::IndexRebuild.create!(project_id:, index_name: fresh.name)

            relations = relations_for(project_id)
            total = relations.sum(&:count)
            completed = 0
            progress&.call(completed, total)

            relations.each do |relation|
              index = relation.klass.searchkick_index(name: fresh.name)

              relation.find_in_batches(batch_size: BATCH_SIZE) do |batch|
                # full: true skips unpublished records instead of deleting them,
                # since the new index has nothing to delete.
                Searchkick::RecordIndexer.new(index).reindex(batch, mode: :inline, method_name: nil, full: true)
                completed += batch.size
                progress&.call(completed, total)
              end
            end

            REPLAY_PASSES.times { break if replay!(build).zero? }

            with_write_lock(project_id, exclusive: true) do
              replay!(build)
              fresh.refresh
              alias_index.promote(fresh.name)
              build.destroy!
            end

            # Writers target the alias or the index named by an IndexRebuild
            # row, so nothing writes to the old index after the swap.
            alias_index.clean_indices

            fresh.refresh
            { index: fresh.name, documents: fresh.total_docs, fields: field_count(fresh.name) }
          rescue StandardError
            # Before the swap, the old index keeps serving and the new one is
            # deleted, with writers held off.
            if build && !Searchkick.client.indices.exists_alias(name: alias_index.name, index: fresh.name)
              with_write_lock(project_id, exclusive: true) do
                build.destroy!
                fresh.delete
              end
            end

            raise
          end
        end

        # Writes `records` (one class, one project) to every index the layout
        # writes to: the project's alias and any rebuild in progress first, the
        # shared index last. Each document is built once and sent to all of
        # them in one bulk request, so one index refusing it does not stop the
        # others; the refusal is raised afterwards. The caller holds the
        # project's write lock.
        def write(records, klass, project_id)
          build = layout == 'shared' ? nil : rebuild_in_progress(project_id)
          targets = []

          unless layout == 'shared'
            index = project_index(project_id, klass)

            if index.exists?
              targets << index
            elsif per_project? && build.nil?
              # The index is built in full in the background, including this
              # record, so there is nothing to write to yet.
              RebuildIndexJob.perform_later(project_id)
            end

            targets << klass.searchkick_index(name: build.index_name) if build
          end

          unless per_project?
            Reindexable.ensure_index!(klass)
            targets << klass.searchkick_index
          end

          build&.log!(records)
          bulk!(records, targets)
        end

        # Not cached, since a rebuild can start while a request or job runs.
        def rebuild_in_progress(project_id)
          ::OpenGeographies::IndexRebuild.uncached { ::OpenGeographies::IndexRebuild.find_by(project_id:) }
        end

        # One bulk request that writes or deletes `records` in every index in
        # `targets`, building each document once.
        def bulk!(records, targets, deleted_ids: [])
          return if targets.empty? || (records.empty? && deleted_ids.empty?)

          stored, removed = records.partition { |record| record.persisted? && !record.destroyed? && record.should_index? }
          first = targets.first
          documents = stored.map { |record| Searchkick::RecordData.new(first, record).index_data[:index] }
          removals = removed.map { |record| Searchkick::RecordData.new(first, record).delete_data[:delete] } +
            deleted_ids.map { |id| { _index: first.name, _id: id } }

          items = targets.flat_map do |target|
            documents.map { |data| { index: data.merge(_index: target.name) } } +
              removals.map { |data| { delete: data.merge(_index: target.name) } }
          end

          response = Searchkick.client.bulk(body: items)
          return unless response['errors']

          # Deleting a document that is not there is not an error.
          failed = response['items'].map { |item| item['index'] || item['delete'] }.find { |item| item['error'] }
          raise Searchkick::ImportError, "#{failed["error"]} on item with id '#{failed["_id"]}' in #{failed["_index"]}" if failed
        end

        # Reads every record logged during a rebuild again and writes it to the
        # new index, or deletes it there when it is gone, unpublished or no
        # longer in the project. Returns how many were logged.
        def replay!(build)
          changes = build.consume_changes!
          return 0 if changes.empty?

          index_name = build.index_name
          project_model_ids = ::CoreDataConnector::ProjectModel.where(project_id: build.project_id).pluck(:id)

          changes.group_by(&:first).each do |record_type, logged|
            klass = record_type.constantize
            by_id = logged.to_h { |_type, id, document_id| [id.to_i, document_id] }
            found = klass.where(id: by_id.keys, project_model_id: project_model_ids).to_a
            gone = by_id.except(*found.map(&:id)).values

            bulk!(found, [klass.searchkick_index(name: index_name)], deleted_ids: gone)
          end

          changes.size
        end

        # Removes IndexRebuild rows, and their unfinished indexes, left by
        # rebuilds whose process died. The caller holds the build lock, so no
        # other rebuild of the project is running.
        def abandon_rebuilds!(project_id)
          stale = ::OpenGeographies::IndexRebuild.where(project_id:).to_a
          return if stale.empty?

          with_write_lock(project_id, exclusive: true) do
            stale.each do |build|
              client = Searchkick.client
              aliased = client.indices.exists_alias(name: project_index_name(project_id), index: build.index_name)
              client.indices.delete(index: build.index_name) if !aliased && client.indices.exists(index: build.index_name)
              build.destroy!
            end
          end
        end

        # For a record destroyed with its project model and no remembered
        # project: removes its document by id from every project index, and
        # from the shared one while that is still written.
        def remove_everywhere(record)
          klass = record.class

          unless per_project?
            Reindexable.ensure_index!(klass)
            Searchkick::RecordIndexer.new(klass.searchkick_index).reindex([record], mode: :inline, method_name: nil, single: true)
          end

          Searchkick.client.delete_by_query(
            index: "#{klass.searchkick_index.name}_project_*",
            body: { query: { ids: { values: [record.search_document_id.to_s] } } },
            allow_no_indices: true,
            ignore_unavailable: true,
          )
        end

        def relations_for(project_id)
          ::CoreDataConnector::ProjectModel.where(project_id:).group_by(&:model_class).filter_map do |model_class, models|
            name = model_class.to_s.demodulize
            next unless CLASS_NAMES.include?(name)

            "OpenGeographies::V1::#{name}".constantize.where(project_model_id: models.map(&:id))
          end
        end

        def indexable_records?(project_id)
          relations_for(project_id).any?(&:exists?)
        end

        def with_build_lock(project_id)
          connection = ActiveRecord::Base.connection
          connection.execute("SELECT pg_advisory_lock(#{BUILD_LOCK}, #{Integer(project_id)})")
          yield
        ensure
          connection&.execute("SELECT pg_advisory_unlock(#{BUILD_LOCK}, #{Integer(project_id)})")
        end

        def with_write_lock(project_id, exclusive: false)
          connection = ActiveRecord::Base.connection
          mode = exclusive ? '' : '_shared'
          connection.execute("SELECT pg_advisory_lock#{mode}(#{WRITE_LOCK}, #{Integer(project_id)})")
          yield
        ensure
          connection&.execute("SELECT pg_advisory_unlock#{mode}(#{WRITE_LOCK}, #{Integer(project_id)})")
        end

        def count_fields(properties)
          properties.sum do |_name, field|
            1 + count_fields(field['properties'] || {}) + (field['fields'] || {}).size
          end
        end
      end
    end
  end
end
