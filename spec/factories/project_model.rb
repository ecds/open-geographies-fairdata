# frozen_string_literal: true

FactoryBot.define do
  factory :place_model, class: 'CoreDataConnector::ProjectModel' do
    project factory: :project
    model_class { 'CoreDataConnector::Place' }
    name { Faker::Name.unique.name }

    # transient do
    #   place_count { rand(5..10) }
    # end

    # after(:create) do |project_model, evaluator|
    #   places = build_list(:place, evaluator.place_count, project_model:)
    #   names = build_list(:place_name, evaluator.place_count)
    #   places.each_with_index { |place, index| place.place_names << names }
    #   places.each(&:reload)
    #   project_model.reload
    # end
  end

  factory :taxonomy_model, class: 'CoreDataConnector::ProjectModel' do
    project factory: :project
    model_class { 'CoreDataConnector::Taxonomy' }
    name { Faker::Name.unique.name }
  end
end
