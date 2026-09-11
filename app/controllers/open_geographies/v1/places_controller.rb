# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      class PlacesController < ApplicationController
        # Only fields already mapped as exact-match `keyword` (or a keyword
        # sub-property) are here - a raw, non-promoted UDF/relationship is
        # indexed as an object or analyzed text (see Searchable#user_defined_fields
        # /#related), so a terms aggregation on one wouldn't give clean facet
        # buckets without a mapping change (a `.keyword` multi-field) this
        # doesn't make. Bespoke per-atlas fields stay searchable via `q`,
        # just not facetable, until that's worth doing.
        FACETABLE_FIELDS = ['types', 'contained_in_place.name', 'administrative_area.name'].freeze

        # Searchkick's own default (unset `fields:`) targets `_all`, which
        # doesn't exist in this custom mapping (no field named `_all` is
        # defined, and ES 7+ dropped the built-in composite field of that
        # name anyway) - a `q` search would silently match nothing without
        # this. Every place-level (not nested related-record) field mapped
        # with the `og_text` analyzer - see es_mapping.json - so a search
        # matches what a curator actually typed onto the place itself,
        # not incidentally through some unrelated linked record's caption.
        SEARCH_FIELDS = ['name', 'names', 'description', 'short_description', 'address'].freeze

        DEFAULT_PER_PAGE = 25
        MAX_PER_PAGE = 100

        def index
          results = Place.search(
            query_term,
            fields: SEARCH_FIELDS,
            where: where_clause,
            aggs: FACETABLE_FIELDS,
            page:,
            per_page:,
            load: false,
          )

          render(json: {
            results: Array(results),
            meta: {
              page: results.current_page,
              per_page: results.per_page,
              total_count: results.total_count,
              total_pages: results.total_pages,
            },
            facets: format_facets(results.aggs),
          })
        end

        def show
          @record = Place.search(
            '*',
            where: { model_type: 'place', project_id: project_id, slugs: params[:slug] },
            limit: 1,
            load: false,
          ).first
          render(json: @record, status: :ok) and return if @record

          render(json: {}, status: :not_found)
        end

        private

        def query_term
          params[:q].presence || '*'
        end

        # { model_type:, project_id:, <facet field>: [selected values], ... } -
        # facet filters are AND'd together across different fields, OR'd within
        # one field's own selected values (Searchkick's normal `where: {field:
        # [a, b]}` semantics) - "Church or School" within Types, narrowed by
        # whatever's selected for Contained In, and so on.
        def where_clause
          clause = { model_type: 'place', project_id: project_id }
          facet_filters.each { |field, values| clause[field.to_sym] = values }
          clause
        end

        # Only ever reads the FACETABLE_FIELDS keys out of params[:facets] -
        # an unrecognized field name is silently ignored rather than raising,
        # same "don't break the whole request over one bad param" posture as
        # the rest of this API.
        def facet_filters
          raw = params[:facets]
          return {} if raw.blank?

          raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
          raw.slice(*FACETABLE_FIELDS).transform_values { |v| Array(v) }
        end

        def page
          [params[:page].to_i, 1].max
        end

        def per_page
          requested = params[:per_page].to_i
          requested.positive? ? [requested, MAX_PER_PAGE].min : DEFAULT_PER_PAGE
        end

        # Searchkick's #aggs returns the raw ES aggregation shape
        # ({"buckets" => [{"key" =>, "doc_count" =>}, ...]}) keyed by field
        # name - reshaped into {value:, count:} pairs so a client doesn't need
        # to know anything about Elasticsearch's own response format.
        #
        # Counts reflect the *current* filtered result set (aggregations run
        # within the same where-scoped query as the results), so selecting a
        # Types facet value narrows what the Contained In facet shows too -
        # this is the simple/standard behavior, not the more advanced
        # "each facet ignores its own filter but respects the others" pattern
        # some faceted-search UIs use, which would need per-facet post-filter
        # aggregations this doesn't build.
        def format_facets(aggs)
          aggs.transform_values do |agg|
            agg['buckets'].map { |bucket| { value: bucket['key'], count: bucket['doc_count'] } }
          end
        end
      end
    end
  end
end
