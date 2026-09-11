# frozen_string_literal: true

require 'searchkick'

module OpenGeographies
  module V1
    # v1's indexing concern, structurally distinct from (not a subclass/reuse
    # of) OpenGeographies::Searchable: v0 gives every model
    # class its own index, named after the class; v1 gives every model class
    # the *same* index_name ('open_geographies_v1'), so Searchkick writes them
    # all into one shared physical index - the "one mapping serves every
    # atlas" design in og_schema/README.md - discriminated by model_type /
    # model_name rather than by which index a document lives in.
    #
    # Relationship/UDF *promotion* (types, media, contained_in_place, ...)
    # works entirely by exact name match against PromotedRelationships,
    # which is derived from og_schema/canonical_template.json rather than a
    # database flag - see that module for why (short version: a flag would
    # need new columns on ProjectModelRelationship/UserDefinedField in
    # core-data-connector, a repo this engine doesn't own and can't diverge
    # from indefinitely). Everything - promoted or not - still gets indexed
    # under its own raw name-derived key too, same as v0 does today, so a
    # bespoke per-atlas client isn't limited to only the promoted subset.
    module Searchable
      extend ActiveSupport::Concern

      MAPPING_PATH = ::OpenGeographies::Engine.root.join(
        'lib', 'open_geographies_fairdata', 'v1', 'es_mapping.json'
      )
      MAPPING = JSON.parse(File.read(MAPPING_PATH), symbolize_names: true).freeze

      # JSON-LD-style compliance marker: OG is meant as
      # an interoperability protocol, not just this engine's internal
      # response shape - a third party serializing OG-compliant records
      # outside of ever calling this API has no request/URL to infer a
      # version from, so the version has to travel inside the record
      # itself. Not yet a real, dereferenceable JSON-LD context document
      # (no term-to-URI mappings hosted at this URL today) - just a stable
      # version identifier every compliant record carries, reserved ahead
      # of the real spec document existing.
      CONTEXT_URL = 'https://opengeographies.org/api/v1/context.json'

      # How many levels deep a related record's own relationships get
      # expanded when nested inside this record's document (a Place's
      # media[] entries include their own creator/publisher, but *those*
      # don't get their relationships expanded again). v0's equivalent
      # (related_search_data) has no such limit - it recurses for as long
      # as the relationship graph keeps producing new records, which only
      # terminates today because nothing in the current schema happens to
      # cycle back. That's fragile by accident, not by design; this makes
      # the limit explicit instead of trusting the graph shape to stay
      # accidentally acyclic.
      DEFAULT_DEPTH = 1

      # Explicit per-class call rather than a fixed `included do`: v0-style
      # "everything shares one index" was true when this concern only had
      # one caller, but Map Layers needs its own index (bbox geo_shape
      # queries, a different document shape) - see V1::MapLayer. Every
      # including class must call this once; there's no silent default,
      # so it's always visible in the model file which index a class
      # writes to.
      class_methods do
        # Not deep_paging: true - it only ever mattered for its side effect
        # of raising Searchkick's default result size to 1_000_000_000
        # (searchkick/query.rb), since neither controller does real
        # cursor-based deep pagination (search_after) with it. That default
        # only works when the index's own max_result_window was *also* set
        # to match, which Searchkick only does automatically when the index
        # is created through Searchkick itself (.reindex/.create_index) -
        # an index created any other way keeps Elasticsearch's real default
        # (10,000), and a query then asking for a billion 500s outright.
        # Every atlas today is a few hundred records at most; Searchkick's
        # plain default (size: 10_000, no special index setting required)
        # covers that with room to spare, and doesn't depend on every
        # future index always being created exactly one specific way.
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
      # not "https://viaf.org/viaf/143125668/"), so `sameAs` needs the URL built
      # per authority - CoreDataConnector::Authority::* (WebIdentifier's own
      # reconciliation services) don't help here, they call each authority's API
      # for lookup/search, not its public entity page. Only the authorities
      # verified against a real canonical URL pattern are listed; anything else
      # in WebAuthority::SOURCE_TYPES (atom, bnf, dpla, jisc) falls back to the
      # raw stored value rather than risk emitting a fabricated wrong URL.
      IDENTIFIER_URL_BUILDERS = {
        'wikidata' => ->(id) { "https://www.wikidata.org/wiki/#{id}" },
        'geonames' => ->(id) { "https://www.geonames.org/#{id}" },
        'viaf' => ->(id) { "https://viaf.org/viaf/#{id}/" },
      }.freeze

      # Not marked `private`: cross-instance calls (related/summarize invoking
      # these on *other* records' instances) need them callable with an
      # explicit receiver, matching v0's Searchable for the same reason.
      #
      # base_search_data + extras are seeded first and never suffixed - both
      # are developer-controlled (this file, or a model's own #extras
      # override), not curator-entered, so they're structurally guaranteed
      # not to collide with each other. Everything after that is
      # curator-controlled (relationship names, UDF column names) and goes
      # through assign_unique! against the accumulating hash, since Core
      # Data enforces no uniqueness on those names at all - see
      # assign_unique! for why that matters.
      # Searchkick defaults to the record's own numeric id for the ES _id,
      # which collides across models in this engine's one-shared-index
      # design (every V1:: class writes to 'open_geographies_v1' via the
      # same searchable_index call) - a Place 1 and a Taxonomy term 1
      # silently overwrite each other. Reproduced in production: reindexing
      # a project's 4 Places + 2 Types left 4 documents, not 6. uuid is
      # already globally unique per record (Identifiable) and is what
      # clients address records by, so it's the natural _id, not a
      # constructed "#{model_type}:#{id}" string.
      def search_document_id
        uuid
      end

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
          # The parameterized project name, matching what v1's routes
          # actually key on (GET /v1/:project/places/:slug resolves
          # :project via Project#name.parameterize - there's no dedicated
          # slug column on Project). project_id alone can't build a URL:
          # it's fine for a record's own top-level document (the client
          # already knows what project it asked for), but a *nested*
          # summary - Contained In pointing at a record in a different,
          # shared project (see the Administrative Districts project) -
          # would otherwise carry a project_id with no way to turn it into
          # a fetchable link at all.
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

      # {authority, identifier} per schema.org sameAs - derived from Identifiable's
      # web_identifiers association, which several but not all OG-eligible models
      # include, hence the respond_to? guard rather than assuming universality.
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

      # Every scalar UDF this record has a value for, keyed by its
      # column_name (parameterized/underscored) as `{label:, value:}` -
      # that part is ported unchanged from v0, and stays regardless of
      # promotion status, same "index it under its own name too" rule
      # `related` uses.
      #
      # Additionally, per PromotedRelationships.udfs_for: a UDF whose
      # column_name exact-matches a canonical name gets ALSO written under
      # its promoted path, as a bare value (no {label:,value:} wrapper) -
      # a single-segment path like "date" writes a flat key; a dotted path
      # like "source.type"/"source.urls" merges into one `source: {type:,
      # urls:}` object. When a UDF's raw key and promoted path happen to
      # be the same string (e.g. Map Layers' "Description" -> "description"),
      # the promoted (bare-value) write simply overwrites the raw
      # (label/value) write at that key - matching how `related` already
      # collapses raw and promoted keys when a curator used the exact
      # canonical relationship name.
      def user_defined_fields(record = self)
        return {} if record.user_defined.nil?

        fields = record.project_model.user_defined_fields
        promoted = PromotedRelationships.udfs_for(record)

        attributes = {}
        record.user_defined.each do |key, value|
          user_defined_field = fields.find_by(uuid: key)
          next if user_defined_field.nil?

          label = user_defined_field.column_name
          written_key = assign_unique!(attributes, label.parameterize.underscore.to_sym, { label:, value: })

          # A *_facet companion for a curator-picked Select UDF (SearchCollection#facet_field_uuids'
          # actual point) - same mechanism a bespoke taxonomy relationship's own *_facet
          # companion already uses (see #related), so es_mapping.json's facets_as_keyword
          # dynamic template needs nothing new to pick this up. Scoped to Select only:
          # it's the one data type that's actually a fixed, curator-defined option set -
          # RichText/Text/Number/Date aren't meaningfully facetable the same way, and
          # faceting free text would just bloat the index with high-cardinality keyword
          # terms nobody would ever filter on.
          if user_defined_field.data_type == ::UserDefinedFields::UserDefinedField::DATA_TYPES[:select] && value.present?
            assign_unique!(attributes, :"#{written_key}_facet", value)
          end

          # Not collision-guarded: promoted paths are developer-controlled
          # (they come from our own canonical template, not curator input),
          # and a dotted path is *meant* to write into the same top-level
          # key as a sibling UDF's dotted path (source.type + source.urls
          # both target :source) - that's the intended merge, not a clash.
          promoted_path = promoted[label]
          merge_promoted_udf!(attributes, promoted_path, value) if promoted_path
        end

        attributes
      end

      # Per-model override point for fields that don't need the promote
      # mechanism to be safely hand-written today (e.g. Place's geometry).
      def extras
        {}
      end

      # Walks every relationship *from* this record. Everything is indexed
      # under its own name-derived key regardless of promotion status, as
      # whichever shape #relationship_value decides: a bare array of names
      # for a relationship pointing at a Taxonomy (types, denomination,
      # whatever a curator calls it - these exist purely for faceted
      # filtering, not navigation, so a plain string is enough, and that
      # applies to *any* taxonomy relationship, not just canonically-named
      # ones - see the regression this fixed below), or a depth-limited
      # summary object for everything else (contained_in_place, media,
      # creator, ... - these need uuid/slug so a client can link to the
      # record itself). Promoted relationships (exact name match against
      # PromotedRelationships.for(self)) *additionally* get the identical
      # value written under their well-known canonical key.
      #
      # Regression: a non-canonically-named taxonomy relationship (e.g.
      # HRCGA's "Denomination", never in PromotedRelationships since only
      # "Types" is canonical) used to always get the full depth-limited
      # summary shape here, never the bare-name shortcut - that shortcut
      # only ever ran inside the *promoted* write, so "Types" only ended up
      # bare because its promoted write happens to land on the same key and
      # overwrites the raw write (see assign_promoted!). A summary at
      # depth > 0 expands the taxonomy term's own related_to, i.e. every
      # *other* record sharing that term - caught in production where a
      # single church's `denomination` field carried all 148 other churches
      # of the same denomination, each with a full description, ballooning
      # that one Place document. Computing the value once via
      # #relationship_value up front (used for both the raw and promoted
      # writes) fixes this and removes the duplicate computation.
      #
      # `visited` (record_identity(self) by default - see #record_identity)
      # is the trail of records already being serialized higher up the
      # current call stack, threaded through summarize/related/related_to
      # together. Caught in production immediately after the denomination
      # fix above: a Place's own `works[]` entries each re-embedded that
      # *same Place* (a work's related_to at depth 0 walks straight back to
      # the Church it belongs to) - not just wasted size, an actual cycle,
      # since DEFAULT_DEPTH's whole job is bounding one, and skipping any
      # record already in `visited` is what actually does that rather than
      # just capping how many *extra* hops away from the cycle a document
      # can grow.
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

            pairs = records.filter_map do |relation|
              item = related_class(relation.related_record_type).find(relation.related_record_id)
              [relation, item] unless visited.include?(record_identity(item))
            end
            next if pairs.empty?

            items = pairs.map(&:last)
            value = relationship_value(items, rel, depth, visited)
            value = with_relationship_order(value, pairs) unless taxonomy_relationship?(rel)
          else
            relation = ::CoreDataConnector::Relationship.find_by(project_model_relationship: rel, primary_record: self)
            next if relation.nil?

            item = related_class(relation.related_record_type).find(relation.related_record_id)
            next if visited.include?(record_identity(item))

            value = relationship_value(item, rel, depth, visited)
          end

          written_key = assign_unique!(related_records, raw_key, value)
          assign_promoted!(related_records, promoted_key, raw_key, written_key, value) if promoted_key

          # A bespoke taxonomy relationship with no canonical promoted_key
          # (so nothing in es_mapping.json explicitly keyword-maps it the
          # way `types`/`work_type` are) would otherwise fall through the
          # strings_as_text dynamic template as analyzed text once it's a
          # bare string/array - searchable via `q`, but useless for a terms
          # aggregation. facets_as_keyword's `*_facet` dynamic template
          # already exists in the mapping for exactly this; only UDFs
          # documented using it before now. Skipped for promoted taxonomy
          # relationships since those already land on an explicitly-mapped
          # keyword field - coupled to es_mapping.json staying in sync with
          # PromotedRelationships, the same risk already flagged on the
          # Address UDF promotion (see user_defined_fields).
          if promoted_key.nil? && taxonomy_relationship?(rel)
            assign_unique!(related_records, :"#{raw_key}_facet", value)
          end
        end

        related_records
      end

      # The inverse direction - relationships where this record is the
      # *target* - surfaced only when the relationship explicitly allows it
      # (allow_inverse). No promotion pass here: the canonical template
      # only defines promoted names for the forward direction today (e.g.
      # "Contained In" -> contained_in_place, but no promoted name for its
      # "Contains" inverse). If that changes, this needs the same
      # promoted-lookup treatment `related` has.
      #
      # Branches on rel.inverse_multiple, not rel.multiple - the forward
      # and inverse directions have independent cardinality (Core Data
      # gives them separate columns for exactly this: a County has_many
      # Places is multiple=true, but each Place belongs to exactly one
      # County, inverse_multiple=false). v0's equivalent branches on
      # rel.multiple for both directions, which is wrong whenever the two
      # differ - not carried forward here.
      #
      # `visited` - see #related's comment - is what stops this from
      # walking straight back to a record already being serialized higher
      # up the call stack (a work's inverse relationship resolves the exact
      # Place it belongs to, which is *why* this direction is the one that
      # actually produces a cycle - `related`'s forward direction can't, on
      # its own, since it's the same relationship row read the other way).
      def related_to(depth = DEFAULT_DEPTH, visited = [record_identity(self)])
        related_records = {}

        relations = ::CoreDataConnector::ProjectModelRelationship.where(related_model: project_model)

        relations.each do |rel|
          next unless rel.allow_inverse

          key = rel.inverse_name.parameterize.underscore.to_sym

          if rel.inverse_multiple
            records = ::CoreDataConnector::Relationship.where(project_model_relationship: rel, related_record: self)
            next if records.empty?

            items = records.map { |relation| related_class(relation.primary_record_type).find(relation.primary_record_id) }
            items = items.reject { |item| visited.include?(record_identity(item)) }
            next if items.empty?

            value = items.map { |item| summarize(item, depth, visited) }
          else
            relation = ::CoreDataConnector::Relationship.find_by(project_model_relationship: rel, related_record: self)
            next if relation.nil?

            item = related_class(relation.primary_record_type).find(relation.primary_record_id)
            next if visited.include?(record_identity(item))

            value = summarize(item, depth, visited)
          end

          assign_unique!(related_records, key, value)
        end

        related_records
      end

      # Ported from v0 largely as-is: a relationship carrying a Boolean UDF
      # whose column_name contains "featured" promotes whichever related
      # record has that box checked to a singular `{relationship_name}:`
      # key - e.g. Place's featured_media. Distinct from the name-based
      # relationship promotion above: this is curator-defined (any
      # relationship can carry a Featured UDF), not tied to the fixed
      # canonical name list, so there's no compliance concept here, just
      # "index it if it's there."
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

      # CoreDataConnector::Publishable's own `published` column
      # (controllable per-record through the FairData UI), exposed as this
      # API's visibility state - 'published'/'unpublished', matching
      # Publishable's own scope names (`scope :published`/
      # `scope :unpublished`) rather than inventing separate vocabulary.
      # No longer a placeholder - see should_index?'s own comment for how
      # published now gates indexing directly. Still needed as its own
      # field, not made redundant by that gate: #related/#related_to walk
      # the DB relationship graph directly, not through Searchkick's
      # should_index? filter, so an unpublished record can still appear
      # *nested* inside an otherwise-published parent's own document. A
      # client needs this to know to hide an embedded item its parent's
      # own top-level gate didn't catch.
      def visibility
        respond_to?(:published) && !published ? 'unpublished' : 'published'
      end

      # Falls back to the parameterized name both when there's no Slug UDF
      # on the model at all, and when there is one but this particular
      # record's value is blank - found live on HRCGA: some churches have
      # never had a WordPress slug recorded (`user_defined[uuid]` is nil,
      # not just absent from the model), which used to make this method
      # return nil outright rather than degrade to the same fallback
      # #slugs already applies via its own `.compact` + always-appended
      # `name.parameterize`.
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

      # Gates what Searchkick actually indexes - a record with published:
      # false is excluded from a full reindex, and removed by the
      # Reindexable decorator's on-save trigger the moment it's unpublished
      # (its own after_commit fires on every update regardless of which
      # column changed, and Searchkick's RecordIndexer#index_record? checks
      # should_index? the same way it checks destroyed? - false routes to
      # the same bulk_delete path, not just a skipped index write).
      #
      # Deliberately NOT overridden here - this must be defined directly in
      # Searchable, included before `searchable_index` runs in each V1::
      # class body, not in Reindexable (included on the base classes later,
      # via Decorators.apply! in config.to_prepare). Searchkick's own
      # `searchkick` macro only defines its generic always-true
      # should_index? "unless base.method_defined?(:should_index?)" at the
      # moment searchable_index is called - in production, eager loading
      # (which runs searchable_index for every V1:: class) happens before
      # to_prepare, so a Reindexable-based definition would already have
      # lost that race and been silently shadowed by Searchkick's own
      # unconditional version living closer in V1::Place's own ancestor
      # chain. Defining it here, in the module included immediately before
      # searchable_index in the same class body, has no such ordering risk.
      #
      # respond_to? rather than assuming every model has the column: true
      # for all 9 reindexed models as of this writing (confirmed against
      # the schema directly), but this stays correct if a future
      # searchable model doesn't have it, rather than raising.
      def should_index?
        respond_to?(:published) ? published : true
      end

      private

      # Depth-limited summary of a related record: at depth 0, the flat
      # envelope plus its own extras and UDFs (raw and promoted - a UDF is
      # a scalar property of the record itself, not a further relationship
      # hop, so it's included regardless of depth, same as extras), no
      # further relationship expansion (this is what actually stops the
      # recursion, unlike v0's equivalent). Above 0, one more layer of that
      # record's own relationships too.
      #
      # user_defined_fields wasn't included here at all until this was
      # caught while wiring up the HRCGA WordPress template: a nested
      # Work's own "Link" UDF promotes to `url` correctly at the top level
      # (verified against real data), but every nested summary - works[],
      # media[], contained_in_place, anything summarize touches - silently
      # dropped every UDF, raw or promoted, forever, regardless of depth.
      # Goes through assign_unique! same as search_data, since a record's
      # own UDFs/relationships can collide with its own base_search_data
      # keys exactly the same way they can at the top level.
      #
      # `visited` defaults to just `record` itself - the entry point for a
      # summary reached via #related/#related_to below, or the very first
      # call from #search_data at the top of the whole chain. Extended with
      # `record` again (a no-op when it's already the last entry, from that
      # top-of-chain call) before recursing, so descendants know every
      # ancestor already being serialized, not just their immediate parent -
      # see #related's comment for why this exists.
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

      # The value #related writes for any relationship - raw key, and
      # promoted key too when there is one, they're always identical now.
      # Bare name(s) for a relationship pointing at a Taxonomy (facet-only,
      # no navigation needed - true whether or not it's canonically named,
      # see #related's regression note), or a depth-limited summary
      # otherwise (needs uuid/slug so a client can link to it).
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

      # Merges each Relationship join row's own `order` column into its
      # resolved item's summary - dropped entirely by this engine until
      # now. v0's equivalent (Searchable#related, unversioned) already
      # threads this through via related_search_data(order); Tours is the
      # relationship this actually matters for ("Ordered stops via the
      # relationship's order" - canonical_template.json's own Tours
      # doc-comment), but it applies uniformly to any multiple
      # relationship here, same as everything else in this file - Media/
      # Works/People/Places arrays now carry their own curator-set order
      # too, for free. `value` is an array of per-item summary hashes at
      # this point (never called for a taxonomy relationship - see
      # #related - whose value is a bare array of name strings instead,
      # nothing to merge an :order key onto).
      #
      # `order` is genuinely optional, not just nullable: most existing
      # relationships across every atlas were never curator-ordered (the
      # column defaults to nil, and nothing before this made ordering a
      # first-class expectation), so most items simply won't have one.
      # Omitted entirely rather than written as `order: null` - "optional"
      # means a client shouldn't expect the key to exist at all, not that
      # it exists and might be empty. #related's own `.order(:order)`
      # query already sorts items with a real value before any that
      # don't (Postgres' NULLS LAST default for ASC), so an array with no
      # order key anywhere is exactly as meaningful as one with no
      # ordering info to give - arbitrary, DB-default order, same as
      # today.
      def with_relationship_order(value, pairs)
        value.each_with_index.map do |summary, i|
          order = pairs[i].first.order
          order.nil? ? summary : summary.merge(order:)
        end
      end

      # Identity tuple for cycle detection (see #related/#related_to's
      # `visited` param) - class + id, not the record itself, so `visited`
      # can use plain array #include?/| rather than needing a custom
      # equality. record.class is always the V1-namespaced subclass here
      # (self, from whichever V1::<Model>.find(...) started this chain, and
      # every related/related_to resolution via #related_class, which
      # always constructs that same namespace) - safe to compare directly
      # without also normalizing away a v0/v1 class mismatch that can't
      # happen in practice.
      def record_identity(record)
        [record.class.name, record.id]
      end

      # Writes `value` at `key`, appending an incrementing numeric suffix
      # (_2, _3, ...) if `key` is already taken. Core Data enforces no
      # uniqueness on ProjectModelRelationship#name or UserDefinedField
      # #column_name - only `presence` is validated (checked against the
      # gem source directly) - so two different relationships, or two
      # different UDFs, or a relationship and a UDF, genuinely can
      # parameterize to the identical key. A plain hash-key overwrite would
      # drop one value with no trace; suffixing keeps both and makes the
      # collision visible in the response instead of silently losing data.
      # Returns the key actually used, since callers sometimes need to
      # know whether their own write landed cleanly.
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

      # Promoted-key write for `related`. When `promoted_key` is literally
      # the same string as this relationship's own raw key *and* that raw
      # write actually landed there unsuffixed (`written_key == raw_key`),
      # the promoted (cleaner) shape intentionally replaces it - a curator
      # used the exact canonical name, so raw and promoted are the same
      # relationship, not a collision. If the raw write got bumped to
      # `_2` because an *earlier* relationship already held that key, this
      # relationship's promoted value must not fall back to overwriting
      # that earlier relationship's slot - it goes through assign_unique!
      # like any other value instead.
      def assign_promoted!(hash, promoted_key, raw_key, written_key, value)
        if promoted_key == raw_key && written_key == raw_key
          hash[promoted_key] = value
        else
          assign_unique!(hash, promoted_key, value)
        end
      end

      # Writes `value` into `attributes` at a dotted path, creating
      # intermediate hashes as needed ("source.type" + "source.urls" both
      # writing into the same `attributes[:source]` hash).
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
