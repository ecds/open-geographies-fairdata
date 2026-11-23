# frozen_string_literal: true

FactoryBot.define do
  factory :project, class: 'CoreDataConnector::Project' do
    name { Faker::Name.unique.name }
    # Matches AtlasesController's own provisioning default (every wizard-
    # created atlas is discoverable: true) - the v1 public API only serves
    # discoverable projects (see V1::ApplicationController#project_id), so a
    # factory-default project needs to be reachable through it without every
    # spec having to opt in explicitly.
    discoverable { true }

    # after(:create) do |project, evaluator|
    #   create(:place_model)
    # end
  end
end
