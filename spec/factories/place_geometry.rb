# frozen_string_literal: true

FactoryBot.define do
  factory :place_geometry, class: 'CoreDataConnector::PlaceGeometry' do
    geometry { RGeo::Geographic.spherical_factory(srid: 4326).point(-81, 34) }
  end
end
