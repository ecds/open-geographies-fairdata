# frozen_string_literal: true

FactoryBot.define do
  factory :organization, class: 'CoreDataConnector::Organization' do
    project_model factory: :place_model

    transient do
      name { Faker::Company.unique.name }
    end

    after(:build) do |organization, evaluator|
      organization.organization_names << CoreDataConnector::OrganizationName.new(name: evaluator.name, primary: true)
    end

    # See spec/factories/place.rb - a save-time callback in the vendored
    # CoreDataConnector touches primary_name before the after(:build)-
    # appended name above is persisted, permanently caching it (and #name)
    # as nil. Reload once creation is done to bust that stale cache.
    after(:create, &:reload)
  end
end
