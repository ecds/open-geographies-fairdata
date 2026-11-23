# frozen_string_literal: true

FactoryBot.define do
  factory :place_name, class: 'CoreDataConnector::PlaceName' do
    name { Faker::Address.city }
    primary { true }
  end
end
