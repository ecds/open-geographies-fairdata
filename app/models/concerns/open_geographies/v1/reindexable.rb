# frozen_string_literal: true

module OpenGeographies
  module V1
    # Included on the upstream base classes (CoreDataConnector::Place, ::Work,
    # ...) by Decorators.apply!, and not on the V1 subclasses. The V1 classes
    # get Searchkick's own after_commit callback from `searchable_index`, but it
    # only fires for saves made through the V1 class. These tables have no STI
    # `type` column, so a save through the base class (for example an edit in the
    # FairData UI) never becomes a V1 instance and never runs that callback. This
    # concern registers a callback on the base class, which every caller shares.
    #
    # Known gap: OpenGeographies::V1::MapLayer also subclasses
    # CoreDataConnector::Place (a Place playing the "map_layer" role, with its
    # own index; see MapLayer). #og_v1_reindex always resolves a base Place to
    # V1::Place, so a map layer edited through the base class is not routed to
    # V1::MapLayer's index. Handling it would need routing by ProjectModelRole.
    module Reindexable
      extend ActiveSupport::Concern

      included do
        # This must be a single after_commit call. A second call with the same
        # method symbol (:og_v1_reindex) replaces the first registration, so
        # separate calls for create/update and destroy would leave only the last
        # one active. With no `on:` filter the callback runs for create, update
        # and destroy, like Searchkick's own `after_commit :reindex`.
        after_commit :og_v1_reindex
      end

      class << self
        # Suspends the callback for the duration of the block, for bulk
        # operations that would otherwise make one Searchkick round trip per
        # record. The caller must trigger one reindex afterward, limited to the
        # records it wrote. Reindexing a whole model class would rebuild every
        # atlas's data (see ReindexesParent).
        #
        # The previous value is saved and restored, and not simply reset, so
        # nested `disable` calls and concurrent threads do not overwrite each
        # other's state.
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

        # Shared by this concern's callback and ReindexesParent's cascade, which
        # need the same recast and reindex sequence.
        #
        # It uses #recast and not V1::<Model>.find(id), so that create, update and
        # destroy share one code path: a destroyed record's row is already gone,
        # and querying for it would raise RecordNotFound. Recasting keeps the
        # loaded instance's attributes and its destroyed?/persisted? state, which
        # Searchkick's RecordIndexer#index_record? uses to choose between
        # reindexing and removing the document.
        def reindex_record(record)
          return if disabled?

          v1_class = "OpenGeographies::V1::#{record.class.name.demodulize}".constantize
          v1_record = recast(record, v1_class)
          ensure_index!(v1_class)
          v1_record.reindex
        end

        # Like Rails' #becomes, which merges into the source record's attributes
        # hash in place. A destroyed record's attributes hash is frozen, so that
        # raises FrozenError when this runs after a destroy. This copies the same
        # state #becomes does (attributes, new_record?, previously_new_record?,
        # destroyed?, errors) but dups the attributes hash first so the merge has
        # a mutable hash to write into.
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

        # A per-record `.reindex` (what this concern and ReindexesParent call,
        # which Searchkick calls "single" mode) does not create the index with
        # its configured mapping when the index does not exist. It sends a raw
        # bulk write and Elasticsearch creates the index with dynamic mapping,
        # so fields such as `slug` (keyword in es_mapping.json) become analyzed
        # text and exact `where: { slug: ... }` filters stop matching. Only a
        # class-level `.reindex` creates the index with the mapping. This matters
        # because the first save into a new atlas through the FairData UI can
        # reach this path before any full reindex has run.
        #
        # The rescue handles the "already exists" race, where two records commit
        # at the same time and both find that the index does not exist.
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
