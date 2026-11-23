# frozen_string_literal: true

FactoryBot.define do
  factory :project_model_relationship, class: 'CoreDataConnector::ProjectModelRelationship' do
    primary_model factory: :place_model
    related_model factory: :place_model
    name { Faker::Verb.unique.base.capitalize }
    multiple { false }
    allow_inverse { false }
  end
end
