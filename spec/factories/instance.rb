# frozen_string_literal: true

FactoryBot.define do
  factory :instance, class: 'CoreDataConnector::Instance' do
    project_model factory: :place_model

    transient do
      name { Faker::Book.unique.title }
    end

    after(:build) do |instance, evaluator|
      instance.source_names << CoreDataConnector::SourceName.new(name: evaluator.name, primary: true)
    end

    # See spec/factories/place.rb - a save-time callback in the vendored
    # CoreDataConnector touches primary_name before the after(:build)-
    # appended name above is persisted, permanently caching it (and #name)
    # as nil. Reload once creation is done to bust that stale cache.
    after(:create, &:reload)
  end
end
