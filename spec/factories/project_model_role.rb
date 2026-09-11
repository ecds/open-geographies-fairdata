# frozen_string_literal: true

FactoryBot.define do
  # ProjectModelRole has no `belongs_to :project_model` association (just a
  # project_model_id column + a plain finder method), so this needs an
  # explicit transient + project_model_id=, not FactoryBot's normal
  # association shorthand.
  factory :project_model_role, class: 'OpenGeographies::ProjectModelRole' do
    transient do
      project_model_record { create(:place_model) }
    end

    project_model_id { project_model_record.id }
    role { 'primary_place' }
  end
end
