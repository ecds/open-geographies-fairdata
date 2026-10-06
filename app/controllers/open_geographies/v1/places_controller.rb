# frozen_string_literal: true

module OpenGeographies
  module V1
    class PlacesController < ApplicationController
      # Only fields already mapped as exact-match `keyword` (or a keyword
      # sub-property) are facetable. A raw, non-promoted user-defined field or
      # relationship is indexed as an object or analyzed text (see
      # Searchable#user_defined_fields and #related), so a terms aggregation on it
      # would not give clean buckets without a `.keyword` multi-field in the
      # mapping. Those fields are still searchable through `q`.
      FACETABLE_FIELDS = ['types', 'contained_in_place.name', 'administrative_area.name'].freeze

      # Searchkick searches `_all` by default, which does not exist in this
      # mapping (Elasticsearch 7+ removed that composite field), so a `q` search
      # would match nothing without an explicit list. These are the place-level
      # (not nested related-record) fields mapped with the og_text analyzer in
      # es_mapping.json, so a search matches text entered on the place itself and
      # not text from a linked record such as a caption.
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

      # { model_type:, project_id:, <facet field>: [selected values], ... }
      # Facet filters are combined with AND across different fields and OR
      # across the selected values of one field (Searchkick's usual
      # `where: {field: [a, b]}` behavior), so "Park or Cemetery" within Types
      # is narrowed further by whatever is selected for Contained In.
      def where_clause
        clause = { model_type: 'place', project_id: project_id }
        facet_filters.each { |field, values| clause[field.to_sym] = values }
        clause
      end

      # Only the FACETABLE_FIELDS keys are read from params[:facets]. An
      # unrecognized field name is ignored and does not fail the request.
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
