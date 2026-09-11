# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      # Included directly on the upstream base classes (CoreDataConnector::Place,
      # ::Work, ...) via Decorators.apply! - NOT on the V1:: subclasses. The
      # V1:: classes already get Searchkick's own after_commit callback for
      # free (from calling `searchable_index`), but that callback only ever
      # fires for saves that go through the V1:: class itself. There's no STI
      # `type` column on these tables, so a save through the base class (e.g.
      # anything editing a record via FairData UI, which has no reason to know
      # the V1:: namespace exists) never becomes a V1:: instance and never
      # runs that callback. This concern closes that gap by registering its
      # own callback directly on the base class, which every caller shares.
      #
      # KNOWN GAP: CoreDataConnector::OpenGeographies::V1::MapLayer also
      # subclasses CoreDataConnector::Place (a Place-class record playing a
      # "map_layer" role, same table, its own separate ES index - see
      # MapLayer's own header comment). #og_v1_reindex below always resolves
      # a base Place save to V1::Place specifically (via
      # self.class.name.demodulize), so a Map-Layer-role Place edited through
      # the base class does NOT get routed to V1::MapLayer's index. Not
      # handled here - would need role-aware routing (ProjectModelRole) this
      # concern doesn't have context for yet.
      module Reindexable
        extend ActiveSupport::Concern

        included do
          # ONE after_commit call, not one per action - a second after_commit
          # call with the same method-symbol filter (:og_v1_reindex) REPLACES
          # the first registration in Rails' callback chain rather than
          # adding a second one, since they share the same filter identity.
          # Found live: splitting this into on: [:create, :update] and
          # on: :destroy calls silently meant only the second (destroy) one
          # ever actually fired - create/update never reindexed anything.
          # No `on:` filter at all = fires for create, update, AND destroy
          # (Rails' default), matching Searchkick's own bare `after_commit
          # :reindex` registration.
          after_commit :og_v1_reindex
        end

        class << self
          # Suspends the callback below for the duration of the block - for
          # bulk operations (ImportPlacesJob, any future bulk write) that
          # would otherwise fire one Searchkick round-trip per record. The
          # caller is responsible for triggering one coalesced reindex
          # afterward, scoped to whatever it actually just wrote (see
          # ReindexesParent's own note on scope - reindexing an entire model
          # class would rebuild every atlas' data, not just the one just
          # imported into).
          #
          # Thread-local with explicit save/restore, not a flat assignment,
          # so nested `disable` calls (or another thread/job running
          # concurrently) can't clobber each other's state.
          def disable
            previous = Thread.current[:core_data_connector_og_v1_reindex_disabled]
            Thread.current[:core_data_connector_og_v1_reindex_disabled] = true
            yield
          ensure
            Thread.current[:core_data_connector_og_v1_reindex_disabled] = previous
          end

          def disabled?
            Thread.current[:core_data_connector_og_v1_reindex_disabled] == true
          end

          # Shared by this concern's own callback and ReindexesParent's
          # cascade - both need the identical recast+reindex sequence, so it
          # lives here once rather than duplicated in both files.
          #
          # #recast (below), not V1::<Model>.find(id): this needs to handle
          # create, update, AND destroy with one code path, and a destroyed
          # record's row is already gone by the time this runs - re-querying
          # it would just raise RecordNotFound. Recasting carries over this
          # already-loaded instance's attributes AND its destroyed?/
          # persisted? state (confirmed directly against the pinned gem
          # sources: searchkick-5.4.0's RecordIndexer#index_record? checks
          # persisted? && !destroyed? to decide reindex vs.
          # remove-from-index) - so the same call correctly reindexes on
          # create/update and removes from the index on destroy.
          def reindex_record(record)
            return if disabled?

            v1_class = "CoreDataConnector::OpenGeographies::V1::#{record.class.name.demodulize}".constantize
            v1_record = recast(record, v1_class)
            ensure_index!(v1_class)
            v1_record.reindex
          end

          # Rails' own #becomes (activerecord-8.1.3.1's Persistence#becomes)
          # does `@attributes.reverse_merge!(...)` - it mutates the SOURCE
          # record's own attributes hash in place, then hands that same hash
          # to the recast copy. That's fine for a live record, but this
          # callback runs post-destroy for the destroy case, and Rails
          # freezes a destroyed record's @attributes hash - the in-place
          # mutation then raises FrozenError. This is #becomes' own
          # algorithm (attributes, new_record?, previously_new_record?,
          # destroyed?, errors - all copied the same way), with one change:
          # .dup the attributes hash first so the merge has something
          # mutable to write into, instead of `record`'s own (possibly
          # frozen) hash.
          def recast(record, klass)
            became = klass.allocate
            became.send(:initialize) do |becoming|
              attributes = record.instance_variable_get(:@attributes).dup
              attributes.reverse_merge!(becoming.instance_variable_get(:@attributes))
              becoming.instance_variable_set(:@attributes, attributes)
              becoming.instance_variable_set(:@new_record, record.new_record?)
              becoming.instance_variable_set(:@previously_new_record, record.previously_new_record?)
              becoming.instance_variable_set(:@destroyed, record.destroyed?)
              becoming.errors.copy!(record.errors)
            end
            became
          end

          # A per-record `.reindex` call (what this concern and
          # ReindexesParent both do - Searchkick calls it "single" mode)
          # does NOT create the index with its configured mapping if the
          # index doesn't exist yet - it fires a raw bulk write, and
          # Elasticsearch auto-creates the index itself with dynamic mapping
          # instead of es_mapping.json's. Found live: `slug` (mapped
          # `keyword` in es_mapping.json) silently became analyzed `text`
          # this way - a bare `'*'` search still found the document, but an
          # exact `where: { slug: ... }` term filter matched nothing, even
          # though the document genuinely existed with that value. Only a
          # full class-level `.reindex` (what every existing spec in this
          # suite calls, and what a real reindex/provisioning job does) goes
          # through Searchkick's own mapping-aware index creation - this
          # matters here specifically because a curator's first save into a
          # brand-new atlas via FairData UI, before any full reindex has
          # ever run, is now exactly this Reindexable-triggered path.
          # Rescues the narrow "already exists" race (two records committing
          # concurrently both seeing exists? == false) rather than letting
          # the second one's index write fail outright.
          def ensure_index!(klass)
            index = klass.searchkick_index
            return if index.exists?

            index.create(index.index_options)
          rescue StandardError => e
            raise unless e.message.include?('resource_already_exists_exception')
          end
        end

        private

        def og_v1_reindex
          Reindexable.reindex_record(self)
        end
      end
    end
  end
end
