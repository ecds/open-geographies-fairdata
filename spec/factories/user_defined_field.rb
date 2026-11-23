# frozen_string_literal: true

FactoryBot.define do
  factory :user_defined_field, class: 'UserDefinedFields::UserDefinedField' do
    defineable factory: :place_model
    column_name { Faker::Verb.unique.base.capitalize }
    data_type { 'String' }
    order { 0 }
  end
end
