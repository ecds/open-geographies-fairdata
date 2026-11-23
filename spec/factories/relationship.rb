# frozen_string_literal: true

FactoryBot.define do
  factory :relationship, class: 'CoreDataConnector::Relationship' do
    project_model_relationship
    primary_record factory: :place
    related_record factory: :place
  end
end
