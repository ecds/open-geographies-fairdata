# frozen_string_literal: true

FactoryBot.define do
  factory :taxonomy, class: 'CoreDataConnector::Taxonomy' do
    project_model factory: :taxonomy_model
    name { Faker::Commerce.unique.department }
  end
end
