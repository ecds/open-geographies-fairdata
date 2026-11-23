# frozen_string_literal: true

FactoryBot.define do
  factory :place, class: 'CoreDataConnector::Place' do
    user_defined do
      {
        Faker::Internet.unique.uuid => 'Description',
      }
    end

    # A Place needs a primary PlaceName to pass validation
    # (Nameable#validate_names), so create(:place, ...) would fail without it.
    transient do
      name { Faker::Address.unique.city }
    end

    after(:build) do |place, evaluator|
      place.place_names << CoreDataConnector::PlaceName.new(name: evaluator.name, primary: true)
    end

    # Reloads the record after creation. Save-time callbacks (Auditable,
    # Publishable, ...) can touch `primary_name` during the parent's own save,
    # before the place_names entry built above is persisted, which caches
    # primary_name (and #name, which delegates to it) as nil. The name cannot be
    # created in after(:create) instead, because Nameable#validate_names needs a
    # primary name to exist at the initial save. Reloading clears every
    # association cache regardless of which callback caused it.
    after(:create, &:reload)
  end
end
