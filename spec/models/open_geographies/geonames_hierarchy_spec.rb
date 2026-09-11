# frozen_string_literal: true

require 'rails_helper'

RSpec.describe(CoreDataConnector::OpenGeographies::GeonamesHierarchy) do
  # extendedFindNearbyJSON's real shape: a mix of "A" (administrative
  # boundary) and "P" (populated place) features, most-specific-first. Only
  # the "A" ones should survive .fetch - the "P" entry (the city/town
  # itself) is redundant with the OG place's own name.
  let(:geonames_response) do
    {
      'geonames' => [
        { 'fcl' => 'P', 'fcode' => 'PPLA2', 'name' => 'Atlanta', 'geonameId' => 4180439 },
        { 'fcl' => 'A', 'fcode' => 'ADM2', 'name' => 'Fulton County', 'geonameId' => 4219762 },
        { 'fcl' => 'A', 'fcode' => 'ADM1', 'name' => 'Georgia', 'geonameId' => 4197000 },
        { 'fcl' => 'A', 'fcode' => 'PCLI', 'name' => 'United States', 'geonameId' => 6252001 },
      ],
    }.to_json
  end

  around do |example|
    original = ENV['GEONAMES_USERNAME']
    ENV['GEONAMES_USERNAME'] = 'test_user'
    example.run
    ENV['GEONAMES_USERNAME'] = original
  end

  def stub_geonames(status: 200, body: geonames_response)
    response = instance_double(Net::HTTPResponse, body:)
    allow(response).to(receive(:is_a?).with(Net::HTTPSuccess).and_return(status == 200))
    allow(Net::HTTP).to(receive(:start).and_return(response))
  end

  describe '.fetch' do
    it 'keeps only administrative-boundary features, most-specific-first, with a built geonames_url' do
      stub_geonames

      result = described_class.fetch(lat: 33.749, lng: -84.388)

      expect(result).to(eq([
        { level: 'ADM2', name: 'Fulton County', geonames_id: '4219762', geonames_url: 'https://www.geonames.org/4219762' },
        { level: 'ADM1', name: 'Georgia', geonames_id: '4197000', geonames_url: 'https://www.geonames.org/4197000' },
        { level: 'PCLI', name: 'United States', geonames_id: '6252001', geonames_url: 'https://www.geonames.org/6252001' },
      ]))
    end

    # Not an edge case - checked against 15 real HRCGA church locations and
    # every single one came back this way, zero as the `geonames` array
    # shape above. GeoNames switches to its US Census street-level
    # reverse-geocoder whenever a point resolves close enough to a mapped
    # address, which real building geometry does essentially every time.
    it 'parses the address shape (US Census street-level reverse-geocoding) when that answers instead' do
      stub_geonames(body: {
        'address' => {
          'adminName2' => 'Grady',
          'adminName1' => 'Georgia',
          'countryCode' => 'US',
          'street' => 'Meridian Rd',
          'streetNumber' => '550',
        },
      }.to_json)

      result = described_class.fetch(lat: 30.727751, lng: -84.136548)

      expect(result).to(eq([
        { level: 'ADM2', name: 'Grady', geonames_id: nil, geonames_url: nil },
        { level: 'ADM1', name: 'Georgia', geonames_id: nil, geonames_url: nil },
        { level: 'PCLI', name: 'US', geonames_id: nil, geonames_url: nil },
      ]))
    end

    it 'skips blank fields in the address shape rather than emitting empty entries' do
      stub_geonames(body: { 'address' => { 'adminName1' => 'Georgia', 'countryCode' => 'US' } }.to_json)

      result = described_class.fetch(lat: 30.727751, lng: -84.136548)

      expect(result).to(eq([
        { level: 'ADM1', name: 'Georgia', geonames_id: nil, geonames_url: nil },
        { level: 'PCLI', name: 'US', geonames_id: nil, geonames_url: nil },
      ]))
    end

    it 'returns nil on a non-2xx response' do
      stub_geonames(status: 500, body: 'error')
      expect(described_class.fetch(lat: 33.749, lng: -84.388)).to(be_nil)
    end

    it 'returns nil on a GeoNames error payload (200 OK with a status key, e.g. bad username)' do
      stub_geonames(body: { 'status' => { 'message' => 'invalid username', 'value' => 10 } }.to_json)
      expect(described_class.fetch(lat: 33.749, lng: -84.388)).to(be_nil)
    end

    it 'returns nil rather than raising on a network failure' do
      allow(Net::HTTP).to(receive(:start).and_raise(Net::OpenTimeout))
      expect(described_class.fetch(lat: 33.749, lng: -84.388)).to(be_nil)
    end
  end

  describe '.lookup' do
    let(:place) { create(:place, project_model: create(:place_model)) }

    it 'fetches and caches on a cold cache' do
      stub_geonames
      expect(Net::HTTP).to(receive(:start).once)

      result = described_class.lookup(place_id: place.id, lat: 33.749, lng: -84.388)

      expect(result.first[:name]).to(eq('Fulton County'))
      expect(described_class.find_by(place_id: place.id).hierarchy.first[:name]).to(eq('Fulton County'))
    end

    it 'reuses the cache when lat/lng have not moved - no second GeoNames call' do
      stub_geonames
      described_class.lookup(place_id: place.id, lat: 33.749, lng: -84.388)

      expect(Net::HTTP).not_to(receive(:start))
      result = described_class.lookup(place_id: place.id, lat: 33.749, lng: -84.388)
      expect(result.first[:name]).to(eq('Fulton County'))
    end

    it 're-fetches when lat/lng moved (geometry changed)' do
      stub_geonames
      described_class.lookup(place_id: place.id, lat: 33.749, lng: -84.388)

      moved_response = { 'geonames' => [{ 'fcl' => 'A', 'fcode' => 'ADM1', 'name' => 'California', 'geonameId' => 5332921 }] }.to_json
      stub_geonames(body: moved_response)

      result = described_class.lookup(place_id: place.id, lat: 34.0, lng: -118.0)
      expect(result.first[:name]).to(eq('California'))
    end

    it 'falls back to the stale cache on a live failure rather than losing the data' do
      stub_geonames
      described_class.lookup(place_id: place.id, lat: 33.749, lng: -84.388)

      allow(Net::HTTP).to(receive(:start).and_raise(Net::OpenTimeout))
      result = described_class.lookup(place_id: place.id, lat: 34.0, lng: -118.0)

      expect(result.first[:name]).to(eq('Fulton County'))
    end

    it 'returns [] on a cold cache with no fallback available' do
      allow(Net::HTTP).to(receive(:start).and_raise(Net::OpenTimeout))
      expect(described_class.lookup(place_id: place.id, lat: 33.749, lng: -84.388)).to(eq([]))
    end
  end
end
