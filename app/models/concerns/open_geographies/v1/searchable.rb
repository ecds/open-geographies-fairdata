# frozen_string_literal: true

require 'searchkick'

module OpenGeographies
  module V1
    # Indexing concern for v1 models. Every including class shares the same
    # index ('open_geographies_v1'), so one physical index holds all of them,
    # and documents are told apart by model_type / model_name and not by which
    # index they live in.
    #
    # Promotion of relationships and user-defined fields (types, media,
    # contained_in_place, ...) works by exact name match against
    # PromotedRelationships, which is derived from the canonical template and
    # needs no database flag. Every relationship and field, promoted or not,
    # is also indexed under its own name-derived key, so a custom client is
    # not limited to the promoted subset.
    module Searchable
      extend ActiveSupport::Concern

      MAPPING_PATH = ::OpenGeographies::Engine.root.join(
        'lib', 'open_geographies_fairdata', 'v1', 'es_mapping.json'
      )
      MAPPING = JSON.parse(File.read(MAPPING_PATH), symbolize_names: true).freeze

      # Identifies the version of the record format. It is carried inside each
      # record because a record serialized outside this API has no request URL
      # to infer a version from. This is a stable identifier only: the URL does
      # not yet serve a JSON-LD context document.
      CONTEXT_URL = 'https://opengeographies.org/api/v1/context.json'

      # How many levels of a related record's own relationships are expanded
      # when it is nested inside another record's document. A place's media
      # entries include their own creator and publisher, for example, but
      # those are not expanded further. The limit also bounds recursion
      # through relationship graphs that contain cycles.
      DEFAULT_DEPTH = 1

      class_methods do
        # Each including class calls this once to name the index it writes to,
        # so the index is always visible in the model file. Map Layers use
        # their own index because their documents have a different shape (see
        # V1::MapLayer).
        #
        # `deep_paging: true` is not set. It raises Searchkick's default result
        # size to 1_000_000_000, which only works when the index's
        # max_result_window was raised to match, and Searchkick does that only
        # for indexes it creates itself. On any other index such a query fails.
        # The plain default (size 10_000) needs no special index setting.
        def searchable_index(name, mapping: Searchable::MAPPING)
          searchkick(
            index_name: -> { name },
            callbacks: false,
            mappings: mapping[:mappings],
            settings: mapping[:settings],
          )
        end
      end

      # CoreDataConnector::WebIdentifier stores a bare code (VIAF "143125668",
      # not "https://viaf.org/viaf/143125668/"), so `sameAs` URLs are built per
      # authority. Only authorities with a known canonical URL pattern are
      # listed; any other authority (atom, bnf, dpla, jisc) falls back to the
      # stored value so that no URL is made up.
      IDENTIFIER_URL_BUILDERS = {
        'wikidata' => ->(id) { "https://www.wikidata.org/wiki/#{id}" },
        'geonames' => ->(id) { "https://www.geonames.org/#{id}" },
        'viaf' => ->(id) { "https://viaf.org/viaf/#{id}/" },
      }.freeze

      # Searchkick defaults to the record's numeric id for the Elasticsearch
      # _id, which collides across models that share one index (a Place with
      # id 1 and a Taxonomy term with id 1 would overwrite each other). The
      # uuid is unique per record and is what clients use to address records,
      # so it is used instead.
      def search_document_id
        uuid
      end

      # The methods in this module are public, not private, because they are
      # called with an explicit receiver on other records (see #related and
      # #summarize).
      #
      # The base data and #extras are added first and are never renamed: both
      # come from code, not from curators, so they cannot collide with each
      # other. Everything after that (relationship names, user-defined field
      # names) is curator-controlled and is added through #assign_unique!,
      # because nothing requires those names to be unique.
      def search_data
        data = { **base_search_data, **extras }

        [user_defined_fields, related(DEFAULT_DEPTH), related_to(DEFAULT_DEPTH), featured].each do |additions|
          additions.each { |key, value| assign_unique!(data, key, value) }
        end

        data
      end

      def base_search_data
        {
          '@context': CONTEXT_URL,
          uuid:,
          slug:,
          slugs:,
          project_id: project_model.project_id.to_s,
          # The parameterized project name, which is what the v1 routes key on
          # (GET /v1/:project/places/:slug resolves :project through
          # Project#name.parameterize, since Project has no slug column).
          # project_id alone can't be turned into a URL, and a nested summary
          # can point at a record in a different, shared project, so this is
          # needed to build a link to it.
          project: project_model.project.name.parameterize,
          model_type: PromotedRelationships.model_type_for(self),
          model_id: project_model.id.to_s,
          model_name: project_model.name,
          name:,
          visibility:,
          date_modified: updated_at&.iso8601,
          identifiers:,
        }
      end

      # {authority, identifier} pairs, as in schema.org sameAs. They come from
      # Identifiable's web_identifiers association, which only some models
      # include, hence the respond_to? guard.
      def identifiers
        return [] unless respond_to?(:web_identifiers)

        web_identifiers.map do |web_identifier|
          authority = web_identifier.web_authority.source_type
          builder = IDENTIFIER_URL_BUILDERS[authority]
          {
            authority:,
            identifier: builder ? builder.call(web_identifier.identifier) : web_identifier.identifier,
          }
        end
      end

      # Every user-defined field this record has a value for, keyed by its
      # parameterized column name as `{label:, value:}`. This applies whether
      # or not the field is promoted.
      #
      # A field whose column name exactly matches a canonical name (see
      # PromotedRelationships.udfs_for) is also written under its promoted
      # path as a bare value, without the label wrapper. A single-segment path
      # such as "date" writes a flat key; a dotted path such as "source.type"
      # and "source.urls" merges into one `source: {type:, urls:}` object. When
      # the raw key and the promoted path are the same string, the promoted
      # value replaces the raw one.
      def user_defined_fields(record = self)
        return {} if record.user_defined.nil?

        fields = record.project_model.user_defined_fields
        promoted = PromotedRelationships.udfs_for(record)

        attributes = {}
        record.user_defined.each do |key, value|
          user_defined_field = fields.find_by(uuid: key)
          next if user_defined_field.nil?

          label = user_defined_field.column_name
          parameterized_key = label.parameterize.underscore.to_sym

          # A "Slug" field is skipped when its value is already one of the
          # record's #slugs. #slug and #slugs read that field themselves, so
          # writing it again would collide with the `slug:` entry in
          # #base_search_data and #assign_unique! would add a redundant `slug_2`.
          # The check is against all of `slugs`, not just the canonical `slug`,
          # because a disambiguation suffix means the raw value can differ from
          # `slug` while still matching one of the alternates.
          next if parameterized_key == :slug && record.respond_to?(:slugs) && record.slugs.include?(value)

          written_key = assign_unique!(attributes, parameterized_key, { label:, value: })

          # A `*_facet` companion is written for Select fields, whose values
          # come from a fixed set of options and so can be filtered on. The
          # `facets_as_keyword` dynamic template in es_mapping.json maps it as
          # a keyword. Free text and other types are not facetable in a useful
          # way and would add high-cardinality terms to the index.
          if user_defined_field.data_type == ::UserDefinedFields::UserDefinedField::DATA_TYPES[:select] && value.present?
            assign_unique!(attributes, :"#{written_key}_facet", value)
          end

          # Promoted paths are not checked for collisions. They come from the
          # canonical template and not from curators, and a dotted path is
          # meant to write into the same top-level key as its siblings
          # (source.type and source.urls both target :source).
          promoted_path = promoted[label]
          merge_promoted_udf!(attributes, promoted_path, value) if promoted_path
        end

        attributes
      end

      # Override point for fields that are written by hand and not through the
      # promotion mechanism (for example a Place's geometry).
      def extras
        {}
      end

      # Walks every relationship from this record. Each is indexed under its
      # own name-derived key, with the value chosen by #relationship_value: a
      # plain array of names for a relationship that points at a Taxonomy,
      # which only needs to be filtered on, or a depth-limited summary for
      # anything else, which needs a uuid and slug so a client can link to it.
      # A promoted relationship (an exact name match against
      # PromotedRelationships.for(self)) also gets the same value under its
      # canonical key.
      #
      # A taxonomy relationship gets the plain-name form whether or not it is
      # promoted. A summary of a taxonomy term would include every other record
      # that shares the term.
      #
      # `visited` holds the records already being serialized higher up the call
      # stack, and is passed through #summarize, #related and #related_to. A
      # record already in it is skipped, which prevents a record from embedding
      # itself again through a relationship that leads back to it.
      def related(depth = DEFAULT_DEPTH, visited = [record_identity(self)])
        related_records = {}
        promoted = PromotedRelationships.for(self)

        relations = ::CoreDataConnector::ProjectModelRelationship.where(primary_model: project_model)

        relations.each do |rel|
          promoted_key = promoted[rel.name]
          raw_key = rel.name.parameterize.underscore.to_sym

          if rel.multiple
            records = ::CoreDataConnector::Relationship.where(project_model_relationship: rel, primary_record: self).order(:order)
            next if records.empty?

            # find_by and not find: a relationship row can outlive the record it
            # points to, and find would raise and fail this record's whole
            # #search_data. Rows whose record is gone are skipped.
            pairs = records.filter_map do |relation|
              item = related_class(relation.related_record_type).find_by(id: relation.related_record_id)
              next if item.nil? || visited.include?(record_identity(item))

              [relation, item]
            end
            next if pairs.empty?

            items = pairs.map(&:last)
            value = relationship_value(items, rel, depth, visited)
            value = with_relationship_order(value, pairs) unless taxonomy_relationship?(rel)
          else
            relation = ::CoreDataConnector::Relationship.find_by(project_model_relationship: rel, primary_record: self)
            next if relation.nil?

            item = related_class(relation.related_record_type).find_by(id: relation.related_record_id)
            next if item.nil? || visited.include?(record_identity(item))

            value = relationship_value(item, rel, depth, visited)
          end

          written_key = assign_unique!(related_records, raw_key, value)
          assign_promoted!(related_records, promoted_key, raw_key, written_key, value) if promoted_key

          # A taxonomy relationship that is not promoted has no explicit keyword
          # mapping, so its names would be indexed as analyzed text, which is
          # searchable but cannot be used for a terms aggregation. The `*_facet`
          # companion matches the `facets_as_keyword` dynamic template in
          # es_mapping.json. Promoted taxonomy relationships are skipped because
          # they already land on an explicitly mapped keyword field.
          if promoted_key.nil? && taxonomy_relationship?(rel)
            assign_unique!(related_records, :"#{raw_key}_facet", value)
          end
        end

        related_records
      end

      # The inverse direction: relationships where this record is the target.
      # These are only included when the relationship has allow_inverse set.
      # Nothing is promoted here, because the canonical template only names the
      # forward direction ("Contained In" maps to contained_in_place, with no
      # promoted name for its "Contains" inverse). If that changes, this needs
      # the same promoted lookup as #related.
      #
      # It branches on rel.inverse_multiple and not rel.multiple, since the two
      # directions have independent cardinality: a County has many Places
      # (multiple), but each Place belongs to one County (inverse_multiple is
      # false).
      #
      # `visited` (see #related) keeps this from walking back to a record that
      # is already being serialized. The inverse direction is where that
      # happens, because it resolves the record that owns the relationship.
      def related_to(depth = DEFAULT_DEPTH, visited = [record_identity(self)])
        related_records = {}

        relations = ::CoreDataConnector::ProjectModelRelationship.where(related_model: project_model)

        relations.each do |rel|
          next unless rel.allow_inverse

          key = rel.inverse_name.parameterize.underscore.to_sym

          if rel.inverse_multiple
            records = ::CoreDataConnector::Relationship.where(project_model_relationship: rel, related_record: self)
            next if records.empty?

            # find_by and not find, as in #related: relationship rows whose
            # record has been deleted are skipped instead of raising.
            items = records.filter_map { |relation| related_class(relation.primary_record_type).find_by(id: relation.primary_record_id) }
            items = items.reject { |item| visited.include?(record_identity(item)) }
            next if items.empty?

            value = items.map { |item| summarize(item, depth, visited) }
          else
            relation = ::CoreDataConnector::Relationship.find_by(project_model_relationship: rel, related_record: self)
            next if relation.nil?

            item = related_class(relation.primary_record_type).find_by(id: relation.primary_record_id)
            next if item.nil? || visited.include?(record_identity(item))

            value = summarize(item, depth, visited)
          end

          assign_unique!(related_records, key, value)
        end

        related_records
      end

      # A relationship that has a Boolean field whose column name contains
      # "featured" promotes the related record with that box checked to a
      # singular key named after the relationship (for example a Place's
      # featured_media). Any relationship can carry such a field, so this is
      # not tied to the canonical names.
      def featured
        featured_recs = {}

        relations = ::CoreDataConnector::ProjectModelRelationship.where(primary_model: project_model)

        featureable_fields = relations.flat_map do |rel|
          rel.user_defined_fields.select { |ud| ud.column_name.downcase.include?('featured') && ud.data_type == 'Boolean' }
        end.compact

        featureable_fields.each do |featured_field|
          project_model_relationship = ::CoreDataConnector::ProjectModelRelationship.find(featured_field.defineable_id)
          rels = ::CoreDataConnector::Relationship.where(project_model_relationship:, primary_record: self)
          featured_rel = rels.find { |rel| rel.user_defined[featured_field.uuid] }
          next if featured_rel.nil?

          item = related_class(featured_rel.related_record_type).find(featured_rel.related_record_id)
          key = project_model_relationship.name.parameterize.underscore.singularize.to_sym
          assign_unique!(featured_recs, key, summarize(item, 0))
        end

        featured_recs
      end

      # The record's `published` flag (set per record in the FairData UI),
      # exposed as 'published' or 'unpublished'.
      #
      # The field is still needed even though #should_index? keeps unpublished
      # records out of the index. #related and #related_to read the database
      # directly and do not go through that check, so an unpublished record can
      # still appear nested inside a published parent's document, and a client
      # needs this value to know to hide it.
      def visibility
        respond_to?(:published) && !published ? 'unpublished' : 'published'
      end

      # The slug comes from a field whose column name contains "slug". It falls
      # back to the parameterized name when the model has no such field or this
      # record's value is blank, the same fallback #slugs always includes.
      def slug
        ud_slug = project_model.user_defined_fields.find { |ud| ud.column_name.downcase.include?('slug') }
        value = ud_slug && user_defined[ud_slug.uuid]
        value.presence || name.parameterize
      end

      def slugs
        ud_slugs = project_model.user_defined_fields
          .filter { |ud| ud.column_name.downcase.include?('slug') }
          .map { |ud| user_defined[ud.uuid] }

        [*ud_slugs, name.parameterize].compact.uniq
      end

      # Controls what Searchkick indexes. A record with published: false is
      # left out of a full reindex, and is removed from the index when it is
      # saved as unpublished (the Reindexable decorator reindexes on every
      # commit, and Searchkick deletes a record for which should_index? is
      # false).
      #
      # This must be defined here, in a module included before
      # `searchable_index` runs in each V1 class body, and not in Reindexable.
      # The `searchkick` macro defines its own always-true should_index? unless
      # the method already exists when it runs, and in production eager
      # loading runs it before Reindexable is applied, so a Reindexable
      # definition would be shadowed by Searchkick's.
      #
      # respond_to? guards against a searchable model that has no `published`
      # column.
      def should_index?
        respond_to?(:published) ? published : true
      end

      private

      # A depth-limited summary of a related record. At depth 0 it is the base
      # data plus the record's own extras and user-defined fields, with no
      # further relationships; those are scalar properties of the record, so
      # they are included at any depth. Above 0, one more layer of the record's
      # relationships is added.
      #
      # `visited` defaults to the record itself. It is extended with the record
      # before recursing, so descendants know every ancestor that is being
      # serialized and not just their immediate parent (see #related).
      def summarize(record, depth, visited = [record_identity(record)])
        base = { **record.base_search_data, **record.extras }
        record.user_defined_fields.each { |key, value| assign_unique!(base, key, value) }
        return base if depth <= 0

        child_visited = visited | [record_identity(record)]
        [record.related(depth - 1, child_visited), record.related_to(depth - 1, child_visited)].each do |additions|
          additions.each { |key, value| assign_unique!(base, key, value) }
        end
        base
      end

      # The value #related writes for a relationship, under both its raw and
      # its promoted key. A relationship that points at a Taxonomy gets bare
      # names, since it is only filtered on. Any other relationship gets a
      # depth-limited summary, which carries the uuid and slug a client needs
      # to link to the record.
      def relationship_value(items_or_item, rel, depth, visited)
        if taxonomy_relationship?(rel)
          if items_or_item.is_a?(Array)
            items_or_item.map(&:name)
          else
            items_or_item.name
          end
        elsif items_or_item.is_a?(Array)
          items_or_item.map { |item| summarize(item, depth, visited) }
        else
          summarize(items_or_item, depth, visited)
        end
      end

      def taxonomy_relationship?(rel)
        rel.related_model.model_class == 'CoreDataConnector::Taxonomy'
      end

      # Adds each relationship row's own `order` value to the summary of the
      # item it resolved to. `value` is an array of summary hashes, one per
      # pair (taxonomy relationships never reach this, since their value is an
      # array of names).
      #
      # `order` is optional: most relationships are never ordered and the
      # column is nil. In that case the key is left out and not written as
      # `order: null`, so a client should not expect it to exist. #related
      # sorts with `.order(:order)`, and Postgres puts nulls last, so ordered
      # items come before unordered ones.
      def with_relationship_order(value, pairs)
        value.each_with_index.map do |summary, i|
          order = pairs[i].first.order
          order.nil? ? summary : summary.merge(order:)
        end
      end

      # Identity used for cycle detection (see `visited` in #related): class
      # name and id, so `visited` can use plain array #include? and |. The
      # class is always the V1-namespaced one, since every record here comes
      # from V1 models or through #related_class.
      def record_identity(record)
        [record.class.name, record.id]
      end

      # Writes `value` at `key`, adding a numeric suffix (_2, _3, ...) when
      # `key` is already taken. Core Data only requires relationship names and
      # user-defined field names to be present, not unique, so two of them can
      # parameterize to the same key. Suffixing keeps both values and makes the
      # collision visible, where a plain hash write would silently drop one.
      # Returns the key that was used.
      def assign_unique!(hash, key, value)
        candidate = key
        n = 2
        while hash.key?(candidate)
          candidate = :"#{key}_#{n}"
          n += 1
        end
        hash[candidate] = value
        candidate
      end

      # Writes the promoted-key value for #related. When the promoted key is
      # the same string as the relationship's raw key and the raw write landed
      # on it without a suffix, the promoted value replaces it: the curator used
      # the canonical name, so they are the same relationship and not a
      # collision. If the raw write was moved to `_2` because an earlier
      # relationship already held the key, the promoted value must not
      # overwrite that earlier one, so it goes through assign_unique!.
      def assign_promoted!(hash, promoted_key, raw_key, written_key, value)
        if promoted_key == raw_key && written_key == raw_key
          hash[promoted_key] = value
        else
          assign_unique!(hash, promoted_key, value)
        end
      end

      # Writes `value` into `attributes` at a dotted path, creating
      # intermediate hashes as needed ("source.type" and "source.urls" both
      # write into the same `attributes[:source]` hash).
      def merge_promoted_udf!(attributes, path, value)
        segments = path.split('.').map(&:to_sym)
        target = segments[0..-2].reduce(attributes) { |hash, segment| hash[segment] ||= {} }
        target[segments.last] = value
      end

      def related_class(related_record_type)
        "::OpenGeographies::V1::#{related_record_type.split("::").last}".constantize
      end
    end
  end
end
