# frozen_string_literal: true

require 'rails_helper'

# Not tested via a real index (contrast place_indexing_spec.rb) - this is
# specifically #slug/#slugs's own Ruby logic, same convention as
# searchable_spec.rb.
RSpec.describe('V1::Place slug disambiguation') do
  around do |example|
    OpenGeographies::V1::Reindexable.disable { example.run }
  end

  let(:project) { create(:project) }
  let(:place_model) { create(:place_model, project:) }

  def stub_geonames(body)
    response = instance_double(Net::HTTPResponse, body: body.to_json)
    allow(response).to(receive(:is_a?).with(Net::HTTPSuccess).and_return(true))
    allow(Net::HTTP).to(receive(:start).and_return(response))
  end

  def v1(place)
    OpenGeographies::V1::Place.find(place.id)
  end

  it 'falls back to the parameterized name when nothing disambiguates it (no UDF, no Contained In, no geometry)' do
    place = create(:place, project_model: place_model, name: 'Friendship Baptist')

    expect(v1(place).slug).to(eq('friendship-baptist'))
    expect(v1(place).slugs).to(eq(['friendship-baptist']))
  end

  describe 'a curator-built "Contained In" relationship' do
    it "appends the target's name-derived slug, not a numeric suffix" do
      county_model = create(:place_model, project:)
      county = create(:place, project_model: county_model, name: 'Putnam County')
      rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
      church = create(:place, project_model: place_model, name: 'Friendship Baptist')
      create(:relationship, project_model_relationship: rel, primary_record: church, related_record: county)

      expect(v1(church).slug).to(eq('friendship-baptist-putnam-county'))
      expect(v1(church).slugs).to(contain_exactly('friendship-baptist', 'friendship-baptist-putnam-county'))
    end

    it "does not recurse into the target's own suffix, even when the target has its own Contained In relationship" do
      state_model = create(:place_model, project:)
      state = create(:place, project_model: state_model, name: 'Georgia')
      county_model = create(:place_model, project:)
      county = create(:place, project_model: county_model, name: 'Putnam County')
      county_rel = create(:project_model_relationship, primary_model: county_model, related_model: state_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
      create(:relationship, project_model_relationship: county_rel, primary_record: county, related_record: state)

      church_rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
      church = create(:place, project_model: place_model, name: 'Friendship Baptist')
      create(:relationship, project_model_relationship: church_rel, primary_record: church, related_record: county)

      # Not 'friendship-baptist-putnam-county-georgia' - the county's own
      # suffix must not compound into the church's.
      expect(v1(church).slug).to(eq('friendship-baptist-putnam-county'))
    end

    it 'wins over the GeoNames fallback when both are available' do
      county_model = create(:place_model, project:)
      county = create(:place, project_model: county_model, name: 'Putnam County')
      rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
      church = create(:place, project_model: place_model, name: 'Friendship Baptist')
      create(:place_geometry, place: church)
      create(:relationship, project_model_relationship: rel, primary_record: church, related_record: county)

      expect(Net::HTTP).not_to(receive(:start))
      expect(v1(church).slug).to(eq('friendship-baptist-putnam-county'))
    end
  end

  describe 'the GeoNames fallback (no curated relationship)' do
    around do |example|
      original = ENV['GEONAMES_USERNAME']
      ENV['GEONAMES_USERNAME'] = 'test_user'
      example.run
      ENV['GEONAMES_USERNAME'] = original
    end

    it 'appends the reverse-geocoded administrative area when the place has geometry' do
      church = create(:place, project_model: place_model, name: 'Friendship Baptist')
      create(:place_geometry, place: church)
      stub_geonames('address' => { 'adminName2' => 'Putnam', 'adminName1' => 'Georgia', 'countryCode' => 'US' })

      expect(v1(church).slug).to(eq('friendship-baptist-putnam'))
    end

    it 'has nothing to fall back to for a place with no geometry either' do
      church = create(:place, project_model: place_model, name: 'Friendship Baptist')

      expect(Net::HTTP).not_to(receive(:start))
      expect(v1(church).slug).to(eq('friendship-baptist'))
    end
  end

  # Real bug found on real Georgia admin-area data: Georgia (ADM1) has no
  # Contained In relationship of its own, so this fell through to the
  # GeoNames fallback, which reverse-geocodes the state's centroid and
  # returns whatever small ADM2 unit happens to overlap that one point -
  # "georgia-twiggs", not a real containing relationship. Disambiguation
  # only makes sense for records that can plausibly collide by name
  # (churches; counties, in a hypothetical multi-state atlas) - a state
  # has nothing real to disambiguate against, so this level must be
  # skipped outright rather than left to whatever the fallback returns.
  describe 'a top-level admin area (its own Admin Level UDF is ADM1 or broader)' do
    def admin_place(name:, level:, project_model: place_model)
      udf = create(:user_defined_field, defineable: project_model, column_name: 'Admin Level', data_type: 'Select')
      create(:place, project_model:, name:, user_defined: { udf.uuid => level })
    end

    it 'never reaches the GeoNames fallback for an ADM1 record, even with geometry and no Contained In' do
      state = admin_place(name: 'Georgia', level: 'ADM1')
      create(:place_geometry, place: state)
      stub_geonames('address' => { 'adminName2' => 'Twiggs', 'adminName1' => 'Georgia', 'countryCode' => 'US' })

      expect(Net::HTTP).not_to(receive(:start))
      expect(v1(state).slug).to(eq('georgia'))
    end

    it 'skips a PCLI (country-level) record the same way' do
      country = admin_place(name: 'United States', level: 'PCLI')
      create(:place_geometry, place: country)
      stub_geonames('address' => { 'adminName1' => 'Georgia', 'countryCode' => 'US' })

      expect(v1(country).slug).to(eq('united-states'))
    end

    it 'still suffixes an ADM2 record normally - the guard is level-specific, not a blanket admin-area skip' do
      state_model = create(:place_model, project:)
      state = admin_place(name: 'Georgia', level: 'ADM1', project_model: state_model)

      county_model = create(:place_model, project:)
      county_rel = create(:project_model_relationship, primary_model: county_model, related_model: state_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
      county = admin_place(name: 'Putnam', level: 'ADM2', project_model: county_model)
      create(:relationship, project_model_relationship: county_rel, primary_record: county, related_record: state)

      expect(v1(county).slug).to(eq('putnam-georgia'))
    end
  end

  describe 'a blank Slug UDF value' do
    it 'falls back to the parameterized name instead of producing a leading dash' do
      county_model = create(:place_model, project:)
      county = create(:place, project_model: county_model, name: 'Sumter County')
      rel = create(:project_model_relationship, primary_model: place_model, related_model: county_model, name: 'Contained In', multiple: false, allow_inverse: true, inverse_name: 'Contains')
      church = create(:place, project_model: place_model, name: 'Friendship Baptist')
      create(:relationship, project_model_relationship: rel, primary_record: church, related_record: county)
      udf = create(:user_defined_field, defineable: place_model, column_name: 'Slug', data_type: 'String')
      church.update!(user_defined: { udf.uuid => nil })

      expect(v1(church).slug).to(eq('friendship-baptist-sumter-county'))
    end
  end
end
