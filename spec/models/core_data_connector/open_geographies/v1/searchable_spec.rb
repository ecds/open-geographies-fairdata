# frozen_string_literal: true

require 'rails_helper'

RSpec.describe(CoreDataConnector::OpenGeographies::V1::Searchable) do
  # This file tests #search_data's Ruby-hash output directly (see every
  # example below), never real Elasticsearch - unlike places_spec.rb/
  # place_indexing_spec.rb, which explicitly reindex and query a real
  # index. Some scenarios here deliberately construct data that's malformed
  # relative to es_mapping.json on purpose (e.g. the raw-key/canonical-name
  # collision spec below, where a non-taxonomy relationship raw-keys to
  # :types) - Reindexable's now-automatic on-save reindexing would otherwise
  # try to actually write that into the real index and fail with a mapping
  # conflict having nothing to do with what this file is testing.
  around do |example|
    CoreDataConnector::OpenGeographies::V1::Reindexable.disable { example.run }
  end

  let(:project) { create(:project) }
  let(:place_model) { create(:place_model, project:) }
  let(:place) { create(:place, project_model: place_model, name: 'Evergreen Church') }
  let(:v1_place) { CoreDataConnector::OpenGeographies::V1::Place.find(place.id) }

  describe '#base_search_data' do
    it 'carries the fixed envelope, including model_id (not just model_type/model_name)' do
      data = v1_place.base_search_data

      expect(data).to(include(
        uuid: place.uuid,
        slug: 'evergreen-church',
        model_type: 'place',
        model_id: place_model.id.to_s,
        model_name: place_model.name,
        name: 'Evergreen Church',
        visibility: 'published',
      ))
    end

    it 'carries the project as a parameterized slug, not just its numeric id - needed to resolve a v1 URL for a record nested from a different project' do
      other_project = create(:project, name: 'Administrative Districts')
      other_place_model = create(:place_model, project: other_project)
      other_place = create(:place, project_model: other_place_model, name: 'Grady County')
      v1_other_place = CoreDataConnector::OpenGeographies::V1::Place.find(other_place.id)

      data = v1_other_place.base_search_data
      expect(data[:project]).to(eq('administrative-districts'))
      expect(data[:project_id]).to(eq(other_project.id.to_s))
    end

    it "reflects an unpublished record's real state, not the old hardcoded placeholder" do
      place.update_published(false)
      data = CoreDataConnector::OpenGeographies::V1::Place.find(place.id).base_search_data
      expect(data[:visibility]).to(eq('unpublished'))
    end
  end

  describe '#search_document_id' do
    it "is the record's uuid, not its numeric id - the shared index gives every model the same searchable_index, so two different models' numeric ids collide as Searchkick's default ES _id" do
      expect(v1_place.search_document_id).to(eq(place.uuid))
    end

    it 'is distinct across models even when the numeric ids match' do
      taxonomy_model = create(:taxonomy_model, project:)
      taxonomy = create(:taxonomy, project_model: taxonomy_model, name: 'Church')
      v1_taxonomy = CoreDataConnector::OpenGeographies::V1::Taxonomy.find(taxonomy.id)

      # Not asserting place.id == taxonomy.id (Postgres sequences make that
      # unreliable to force) - the real regression is any two models sharing
      # a search_document_id, so this only needs the ids to differ from each
      # other's uuids, which they always will.
      expect(v1_place.search_document_id).not_to(eq(v1_taxonomy.search_document_id))
    end
  end

  describe '#user_defined_fields' do
    it 'indexes a non-promoted UDF as {label:, value:} under its parameterized name' do
      udf = create(:user_defined_field, defineable: place_model, column_name: 'Legacy ID', data_type: 'Number')
      place.update!(user_defined: { udf.uuid => 42 })

      fields = v1_place.user_defined_fields
      expect(fields[:legacy_id]).to(eq({ label: 'Legacy ID', value: 42 }))
    end

    it 'additionally promotes a UDF whose column_name exact-matches a canonical name to a bare value' do
      udf = create(:user_defined_field, defineable: place_model, column_name: 'Description', data_type: 'RichText')
      place.update!(user_defined: { udf.uuid => 'A historic church.' })

      fields = v1_place.user_defined_fields
      expect(fields[:description]).to(eq('A historic church.'))
    end

    # Regression: canonical_template.json is what PromotedRelationships reads
    # to decide what's promoted, and es_mapping.json (address: {type: text})
    # is a completely separate file - reconciling one against a teammate's
    # updated draft without the other left `Address` mapped as bare text but
    # never promoted, so it stayed as the raw {label:, value:} object and
    # blew up on real ES insert ("Can't get text on a START_OBJECT") for any
    # real Place with an Address UDF, e.g. real HRCGA church records.
    it 'promotes a Places "Address" UDF to a bare value, matching es_mapping.json\'s address: {type: text}' do
      udf = create(:user_defined_field, defineable: place_model, column_name: 'Address', data_type: 'String')
      place.update!(user_defined: { udf.uuid => '497 Meridian Rd, Thomasville, GA 31792, United States' })

      fields = v1_place.user_defined_fields
      expect(fields[:address]).to(eq('497 Meridian Rd, Thomasville, GA 31792, United States'))
    end

    it 'merges dotted promote paths from different UDFs into one nested object (Map Layers Source Type/Source URLs)' do
      layer_model = create(:place_model, project:)
      create(:project_model_role, project_model_record: layer_model, role: 'map_layer')
      type_udf = create(:user_defined_field, defineable: layer_model, column_name: 'Source Type', data_type: 'Select')
      urls_udf = create(:user_defined_field, defineable: layer_model, column_name: 'Source URLs', data_type: 'String')
      layer_place = create(:place, project_model: layer_model, user_defined: { type_udf.uuid => 'wms', urls_udf.uuid => ['https://example.com/wms'] })
      v1_map_layer = CoreDataConnector::OpenGeographies::V1::MapLayer.find(layer_place.id)

      expect(v1_map_layer.user_defined_fields[:source]).to(eq({ type: 'wms', urls: ['https://example.com/wms'] }))
    end
  end

  describe '#related' do
    it 'indexes a non-promoted, non-taxonomy relationship under its own raw parameterized key, as a depth-limited summary' do
      publisher_model = create(:place_model, project:, model_class: 'CoreDataConnector::Organization')
      rel = create(:project_model_relationship, primary_model: place_model, related_model: publisher_model, name: 'Steward', multiple: false)
      steward = create(:organization, project_model: publisher_model, name: 'Friends of the Church')
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: steward)

      expect(v1_place.related[:steward]).to(include(name: 'Friends of the Church'))
    end

    # should_index? (Reindexable) only gates a record's own top-level
    # document - #related walks the DB relationship graph directly, not
    # through Searchkick, so an unpublished related record still appears
    # nested inside an otherwise-published parent's document. visibility is
    # exactly how a client is meant to tell the difference and hide it.
    it "carries an unpublished related record's real visibility in its nested summary, even though it wouldn't get its own top-level document" do
      publisher_model = create(:place_model, project:, model_class: 'CoreDataConnector::Organization')
      rel = create(:project_model_relationship, primary_model: place_model, related_model: publisher_model, name: 'Steward', multiple: false)
      steward = create(:organization, project_model: publisher_model, name: 'Friends of the Church')
      steward.update_published(false)
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: steward)

      expect(v1_place.related[:steward][:visibility]).to(eq('unpublished'))
    end

    # Regression: this used to be the one case the old code got wrong - a
    # non-canonically-named taxonomy relationship (nothing in
    # PromotedRelationships covers "Denomination") always got the full
    # depth-limited summary shape, since the bare-name shortcut only ever
    # ran inside the *promoted* write path. That's fine for `types` (it only
    # ever looked bare because its promoted write happens to land on the
    # same key and overwrite the raw write - see assign_promoted!), but for
    # a relationship with no promoted_key at all, nothing ever overwrote it.
    # A depth-limited summary of a Taxonomy term at depth > 0 expands the
    # term's own related_to - every *other* record sharing that term - so in
    # production, a single HRCGA church's `denomination` field carried all
    # 148 other churches of the same denomination, each with a full
    # description, ballooning that one Place document.
    it 'indexes a non-promoted relationship pointing at a Taxonomy as a bare name, with a _facet companion key' do
      denomination_model = create(:taxonomy_model, project:)
      rel = create(:project_model_relationship, primary_model: place_model, related_model: denomination_model, name: 'Denomination', multiple: false)
      term = create(:taxonomy, project_model: denomination_model, name: 'Congregational')
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: term)

      data = v1_place.related
      expect(data[:denomination]).to(eq('Congregational'))
      expect(data[:denomination_facet]).to(eq('Congregational'))
    end

    it 'promotes a Types relationship pointing at a Taxonomy to a bare array of names (raw and promoted keys coincide)' do
      types_model = create(:taxonomy_model, project:)
      rel = create(:project_model_relationship, primary_model: place_model, related_model: types_model, name: 'Types', multiple: true)
      church = create(:taxonomy, project_model: types_model, name: 'Church')
      school = create(:taxonomy, project_model: types_model, name: 'School')
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: church)
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: school)

      expect(v1_place.related[:types]).to(eq(['Church', 'School']))
    end

    it 'promotes Contained In to a real object under a key distinct from its own raw key' do
      county_model = create(:place_model, project:)
      county = create(:place, project_model: county_model, name: 'Grady County')
      rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false)
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: county)

      data = v1_place.related
      expect(data[:contained_in]).to(include(name: 'Grady County'))
      expect(data[:contained_in_place]).to(include(name: 'Grady County'))
    end

    # Regression: summarize() - used for every nested record (works[],
    # media[], contained_in_place, ...) - never called user_defined_fields
    # at all until now, at any depth. A nested Work's own "Link" UDF
    # promotes to `url` correctly at the top level (verified against real
    # HRCGA data), but every nested summary silently dropped it, raw or
    # promoted, forever - caught while wiring up the WordPress template,
    # which needs works[].url for its sidebar links.
    it 'includes a nested record\'s own UDFs (raw and promoted), not just its relationships' do
      works_model = create(:place_model, project:, model_class: 'CoreDataConnector::Work')
      rel = create(:project_model_relationship, primary_model: place_model, related_model: works_model, name: 'Works', multiple: true)
      link_udf = create(:user_defined_field, defineable: works_model, column_name: 'Link', data_type: 'String')
      legacy_udf = create(:user_defined_field, defineable: works_model, column_name: 'Legacy Note', data_type: 'String')
      work = create(:work, project_model: works_model, user_defined: {
        link_udf.uuid => 'https://example.com/plan-a-trip',
        legacy_udf.uuid => 'internal note',
      })
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: work)

      work_summary = v1_place.related[:works].first
      expect(work_summary[:url]).to(eq('https://example.com/plan-a-trip')) # promoted (canonical Works UDF)
      expect(work_summary[:legacy_note]).to(eq({ label: 'Legacy Note', value: 'internal note' })) # raw, non-promoted
    end

    it 'expands one level of a related record\'s own relationships, then stops (depth capping)' do
      media_model = create(:place_model, project:, model_class: 'CoreDataConnector::MediaContent')
      publisher_model = create(:place_model, project:, model_class: 'CoreDataConnector::Organization')
      media_rel = create(:project_model_relationship, primary_model: place_model, related_model: media_model, name: 'Media', multiple: true)
      publisher_rel = create(:project_model_relationship, primary_model: media_model, related_model: publisher_model, name: 'Publisher', multiple: false)

      media = create(:media_content, project_model: media_model, name: 'A Photo')
      publisher = create(:organization, project_model: publisher_model, name: 'Archive')
      create(:relationship, project_model_relationship: media_rel, primary_record: place, related_record: media)
      create(:relationship, project_model_relationship: publisher_rel, primary_record: media, related_record: publisher)

      media_summary = v1_place.related[:media].first
      expect(media_summary[:name]).to(eq('A Photo'))
      expect(media_summary[:publisher]).to(include(name: 'Archive')) # one level of the media's own relationships
      expect(media_summary[:publisher]).not_to(have_key(:media)) # but no further recursion from there
    end

    # Regression: this engine dropped a multiple relationship's own curator-
    # set order entirely - v0's equivalent (Searchable#related, unversioned)
    # already threads Relationship#order through via related_search_data,
    # but v1's rewrite lost it. Doesn't show up as broken data so much as
    # missing data: Tours exists specifically to be an *ordered* list of
    # stops ("Ordered stops via the relationship's order" - Tours' own
    # canonical_template.json doc-comment), so an unordered `stops[]` quietly
    # defeats the one thing that makes it a Tour rather than a plain set.
    # Exercised here on Media (any multiple relationship, not just Stops) to
    # show it's the generic engine's fix, not a Tour-specific special case.
    it 'threads each multiple relationship item\'s own Relationship#order into its summary, and returns items pre-sorted by it' do
      media_model = create(:place_model, project:, model_class: 'CoreDataConnector::MediaContent')
      rel = create(:project_model_relationship, primary_model: place_model, related_model: media_model, name: 'Media', multiple: true)
      first = create(:media_content, project_model: media_model, name: 'First')
      second = create(:media_content, project_model: media_model, name: 'Second')
      # Created out of order on purpose - creation order must not be what
      # determines the array's order.
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: second, order: 2)
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: first, order: 1)

      media = v1_place.related[:media]
      expect(media.map { |item| item[:name] }).to(eq(['First', 'Second']))
      expect(media.map { |item| item[:order] }).to(eq([1, 2]))
    end

    # "Optional" means a client shouldn't expect the key to exist at all for
    # a relationship nobody ever curator-ordered (the overwhelming common
    # case today - order wasn't a first-class concept before this), not
    # that it exists and might be `null`. Also covers the mixed case:
    # Postgres' NULLS LAST default (the `.order(:order)` query in #related)
    # means an unordered item still lands after every ordered one, so the
    # array stays meaningfully sorted even when only some items have order.
    it 'omits the order key entirely for a relationship with no curator-set order, rather than writing order: null' do
      media_model = create(:place_model, project:, model_class: 'CoreDataConnector::MediaContent')
      rel = create(:project_model_relationship, primary_model: place_model, related_model: media_model, name: 'Media', multiple: true)
      ordered = create(:media_content, project_model: media_model, name: 'Ordered')
      unordered = create(:media_content, project_model: media_model, name: 'Unordered')
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: unordered)
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: ordered, order: 1)

      media = v1_place.related[:media]
      expect(media.map { |item| item[:name] }).to(eq(['Ordered', 'Unordered']))
      expect(media.find { |item| item[:name] == 'Ordered' }).to(have_key(:order))
      expect(media.find { |item| item[:name] == 'Unordered' }).not_to(have_key(:order))
    end

    # Regression: found immediately after the denomination fix above, in the
    # exact same production document - each of a church's own `works[]`
    # entries re-embedded that *same church* under a `church:` key, because a
    # Work's inverse relationship (walked while expanding the work's own
    # related_to at depth 0) resolves straight back to the Place that owns
    # it. The denomination case was a taxonomy term reflecting outward to its
    # *other* members; this is the more direct case of a child pointing
    # straight back to its own parent - both are the same underlying gap
    # (nothing tracked which records were already being serialized higher up
    # the call stack), just reached via different relationship shapes.
    it 'does not re-embed the record itself when a related record\'s inverse relationship points back to it' do
      works_model = create(:place_model, project:, model_class: 'CoreDataConnector::Work')
      works_rel = create(
        :project_model_relationship,
        primary_model: place_model,
        related_model: works_model,
        name: 'Works',
        multiple: true,
        allow_inverse: true,
        inverse_name: 'Church',
      )
      work = create(:work, project_model: works_model, name: 'Cemetery')
      create(:relationship, project_model_relationship: works_rel, primary_record: place, related_record: work)

      work_summary = v1_place.related[:works].first
      expect(work_summary[:name]).to(eq('Cemetery'))
      expect(work_summary).not_to(have_key(:church))
    end

    describe 'key collisions (Core Data enforces no name uniqueness)' do
      it 'suffixes a raw key collision instead of silently dropping one relationship\'s data' do
        taxonomy_model = create(:taxonomy_model, project:)
        rel_a = create(:project_model_relationship, primary_model: place_model, related_model: taxonomy_model, name: 'Denomination', multiple: false)
        rel_b = create(:project_model_relationship, primary_model: place_model, related_model: taxonomy_model, name: 'Denomination', multiple: false)
        term_a = create(:taxonomy, project_model: taxonomy_model, name: 'First')
        term_b = create(:taxonomy, project_model: taxonomy_model, name: 'Second')
        create(:relationship, project_model_relationship: rel_a, primary_record: place, related_record: term_a)
        create(:relationship, project_model_relationship: rel_b, primary_record: place, related_record: term_b)

        data = v1_place.related
        expect(data[:denomination]).to(eq('First'))
        expect(data[:denomination_2]).to(eq('Second'))
        # The _facet companion (see #related) collides and suffixes the same
        # way the raw key does - it goes through the same assign_unique!.
        expect(data[:denomination_facet]).to(eq('First'))
        expect(data[:denomination_facet_2]).to(eq('Second'))
      end

      it 'never lets a later relationship\'s promoted value overwrite an earlier relationship\'s raw slot' do
        # Two relationships both literally named "Types": the first is a plain
        # (non-taxonomy) relationship that happens to raw-key to :types; the
        # second is the real canonical Types relationship, whose raw key
        # collides with the first and gets bumped to :types_2 - its promoted
        # value must follow the bump, not clobber the first relationship's data.
        place_related_model = create(:place_model, project:)
        types_model = create(:taxonomy_model, project:)
        first_rel = create(:project_model_relationship, primary_model: place_model, related_model: place_related_model, name: 'Types', multiple: false)
        second_rel = create(:project_model_relationship, primary_model: place_model, related_model: types_model, name: 'Types', multiple: true)

        other_place = create(:place, project_model: place_related_model, name: 'Not A Taxonomy')
        term = create(:taxonomy, project_model: types_model, name: 'Church')
        create(:relationship, project_model_relationship: first_rel, primary_record: place, related_record: other_place)
        create(:relationship, project_model_relationship: second_rel, primary_record: place, related_record: term)

        data = v1_place.related
        expect(data[:types]).to(include(name: 'Not A Taxonomy')) # first relationship's raw value, untouched
        expect(data.values).to(include(['Church'])) # second relationship's promoted value landed *somewhere* safely
      end
    end
  end

  describe '#related_to' do
    it 'surfaces the inverse relationship under inverse_name when allow_inverse is true' do
      county_model = create(:place_model, project:)
      county = create(:place, project_model: county_model, name: 'Grady County')
      rel = create(:project_model_relationship, primary_model: county_model, related_model: place_model, name: 'Places', multiple: true, allow_inverse: true, inverse_name: 'Contains')
      create(:relationship, project_model_relationship: rel, primary_record: county, related_record: place)

      expect(v1_place.related_to[:contains]).to(include(name: 'Grady County'))
    end
  end

  describe '#featured' do
    # NOTE: the key here is *not* `featured_media` despite this method's own
    # docstring saying "e.g. Place's featured_media" - that comment turned
    # out to be aspirational, never actually verified against real
    # behavior. The real key is just the relationship's own name,
    # parameterized and singularized, with no "featured_" prefix at all -
    # ported faithfully from v0 (CoreDataConnector::OpenGeographies::Searchable#featured
    # does the identical `slug.singularize`, no prefix). For a relationship
    # named "Media" specifically, ActiveSupport's inflector singularizes
    # "media" to "medium" (the singular of "medium/media" in English), which
    # reads oddly but matches both v0 and v1 today - flagged, not changed
    # here, since it's a pre-existing v0 behavior this test should describe
    # accurately, not silently redesign.
    it 'promotes the related record whose Featured UDF is checked to a singular key' do
      media_model = create(:place_model, project:, model_class: 'CoreDataConnector::MediaContent')
      rel = create(:project_model_relationship, primary_model: place_model, related_model: media_model, name: 'Media', multiple: true)
      featured_udf = create(:user_defined_field, defineable: rel, column_name: 'Featured', data_type: 'Boolean', order: 0)

      unfeatured = create(:media_content, project_model: media_model, name: 'Unfeatured')
      featured = create(:media_content, project_model: media_model, name: 'Featured Photo')
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: unfeatured, user_defined: { featured_udf.uuid => false })
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: featured, user_defined: { featured_udf.uuid => true })

      expect(v1_place.featured[:medium]).to(include(name: 'Featured Photo'))
    end
  end

  describe '#search_data' do
    it 'assembles envelope, UDFs, and relationships into one hash, protecting envelope keys from being overwritten' do
      # A relationship literally named "Name" would raw-key to :name, the same
      # key base_search_data uses for the place's own name - base_search_data
      # is seeded first and reserved, so the relationship's data must be
      # suffixed instead of silently clobbering the place's real name.
      other_model = create(:place_model, project:)
      rel = create(:project_model_relationship, primary_model: place_model, related_model: other_model, name: 'Name', multiple: false)
      other = create(:place, project_model: other_model, name: 'Should Not Win')
      create(:relationship, project_model_relationship: rel, primary_record: place, related_record: other)

      data = v1_place.search_data
      expect(data[:name]).to(eq('Evergreen Church'))
      expect(data[:name_2]).to(include(name: 'Should Not Win'))
    end
  end
end
