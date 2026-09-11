# frozen_string_literal: true

require 'rails_helper'

# Real Elasticsearch, not a mock - same rationale as place_indexing_spec.rb:
# facet aggregation buckets, pagination metadata, and text-query relevance
# are exactly the class of behavior a pure-Ruby controller unit test can't
# prove. This hits the real HTTP route and reads back the real ES response.
RSpec.describe('CoreDataConnector::OpenGeographies::V1::Places', type: :request) do
  after do
    index = CoreDataConnector::OpenGeographies::V1::Place.searchkick_index
    index.delete if index.exists?
  end

  it 'supports text search, facet filtering with counts, and pagination' do
    project = create(:project)
    place_model = create(:place_model, project:)
    project_slug = project.name.parameterize

    types_model = create(:taxonomy_model, project:)
    types_rel = create(:project_model_relationship, primary_model: place_model, related_model: types_model, name: 'Types', multiple: true)
    church_type = create(:taxonomy, project_model: types_model, name: 'Church')
    school_type = create(:taxonomy, project_model: types_model, name: 'School')

    # A separate project for the county on purpose: it's a real Place record
    # (model_type: 'place'), so if it lived in `project` it would itself
    # inflate the totals this test asserts below - the "Contained In"
    # relationship works fine across projects for this
    # promotion, and this keeps the county out of the query's own project_id
    # scope, matching how a shared Counties project would actually be used.
    counties_project = create(:project)
    counties_model = create(:place_model, project: counties_project)
    contained_in_rel = create(:project_model_relationship, primary_model: place_model, related_model: counties_model, name: 'Contained In')
    county = create(:place, project_model: counties_model, name: 'Evergreen County')

    churches = create_list(:place, 3, project_model: place_model, name: 'Evergreen Baptist Church')
    schools = create_list(:place, 2, project_model: place_model, name: 'Evergreen Elementary School')
    # Distinctly named (unlike the three identically-named churches above,
    # whose shared slug would make a #show lookup ambiguous) and deliberately
    # left out of the Contained In/Types relationships below, so it doesn't
    # perturb the facet-count/pagination totals asserted elsewhere in this spec.
    abba = create(:place, project_model: place_model, name: 'Abba Baptist')

    (churches + schools).each do |place|
      create(:relationship, project_model_relationship: contained_in_rel, primary_record: place, related_record: county)
    end
    churches.each { |c| create(:relationship, project_model_relationship: types_rel, primary_record: c, related_record: church_type) }
    schools.each { |s| create(:relationship, project_model_relationship: types_rel, primary_record: s, related_record: school_type) }

    CoreDataConnector::OpenGeographies::V1::Place.reindex(refresh: true)

    # --- text search ---
    get "/open_geographies/v1/#{project_slug}/places", params: { q: 'Elementary' }
    expect(response).to(have_http_status(:ok))
    expect(response_json[:results].size).to(eq(2))
    expect(response_json[:results].map { |r| r[:name] }).to(all(eq('Evergreen Elementary School')))

    # --- facet counts on the unfiltered result set ---
    get "/open_geographies/v1/#{project_slug}/places"
    expect(response).to(have_http_status(:ok))
    types_facet = response_json[:facets][:types].sort_by { |b| b[:value] }
    expect(types_facet).to(eq([{ value: 'Church', count: 3 }, { value: 'School', count: 2 }]))
    contained_in_facet = response_json[:facets][:'contained_in_place.name']
    expect(contained_in_facet).to(eq([{ value: 'Evergreen County', count: 5 }]))
    # 6, not 5: `abba` (created above) is a real place in this same project
    # too, just deliberately left out of the Contained In/Types
    # relationships, so it counts toward the unfiltered total without
    # appearing in either facet.
    expect(response_json[:meta][:total_count]).to(eq(6))

    # --- facet filtering narrows both results and the other facet's counts ---
    get "/open_geographies/v1/#{project_slug}/places", params: { facets: { types: ['Church'] } }
    expect(response).to(have_http_status(:ok))
    expect(response_json[:results].size).to(eq(3))
    expect(response_json[:results].map { |r| r[:name] }).to(all(eq('Evergreen Baptist Church')))
    expect(response_json[:meta][:total_count]).to(eq(3))
    narrowed_contained_in = response_json[:facets][:'contained_in_place.name']
    expect(narrowed_contained_in).to(eq([{ value: 'Evergreen County', count: 3 }]))

    # --- pagination ---
    get "/open_geographies/v1/#{project_slug}/places", params: { per_page: 2, page: 2 }
    expect(response).to(have_http_status(:ok))
    expect(response_json[:results].size).to(eq(2))
    expect(response_json[:meta]).to(eq({ page: 2, per_page: 2, total_count: 6, total_pages: 3 }))

    # --- #show, by slug - regression check for the `slugs` mapping bug found
    # live in production: `slugs` (plural, the array PlacesController#show
    # actually filters on) had no explicit mapping and fell through to the
    # strings_as_text dynamic template as analyzed text, so this exact
    # where: { slugs: ... } term filter silently matched nothing even though
    # the record existed with the right value - see es_mapping.json's
    # slugs_comment. `slug` (singular) was always mapped correctly, which is
    # why this only ever showed up on the field #show actually queries. ---
    get "/open_geographies/v1/#{project_slug}/places/#{abba.name.parameterize}"
    expect(response).to(have_http_status(:ok))
    expect(response_json[:name]).to(eq('Abba Baptist'))
  end
end
