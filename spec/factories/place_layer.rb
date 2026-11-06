# frozen_string_literal: true

FactoryBot.define do
  # A PlaceLayer needs either `content` or `url`, so each spec sets the one it
  # is testing.
  factory :place_layer, class: 'CoreDataConnector::PlaceLayer' do
    place
    name { 'Layer' }
    layer_type { 'georeference' }
  end
end
