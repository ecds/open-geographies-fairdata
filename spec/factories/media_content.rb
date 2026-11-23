# frozen_string_literal: true

FactoryBot.define do
  factory :media_content, class: 'CoreDataConnector::MediaContent' do
    project_model factory: :place_model
    name { Faker::Book.unique.title }

    # MediaContent's after_save callback (update_manifests) reaches into
    # Iiif::Manifest - not something a unit test creating a bare
    # MediaContent should depend on. See spec/support/stub_triple_eye_effable_cloud.rb
    # for TripleEyeEffable::Resourceable's before_create/before_update
    # callbacks, the other real-HTTP source here.
    after(:build) do |media_content|
      media_content.define_singleton_method(:update_manifests) {}
    end
  end
end
