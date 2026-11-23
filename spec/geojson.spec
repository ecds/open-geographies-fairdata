# frozen_string_literal: true

require 'rails_helper'

RSpec.describe(CoreDataConnector::OpenGeographies::Geojson) do
  it 'does something' do
    # allow(Rails.env).to receive(:test?).and_return(true)
    puts '^^^^'
    puts FactoryBot.factories.count
    puts '^^^^'
    project = create(:project)
    puts project.name
    project_model = CoreDataConnector::ProjectModel.create(name: project.name, project:, model_class: 'CoreDataConnector::Place')
    place_name = build(:place_name)
    place = build(:place, project_model:)
    place.place_names << place_name
    puts project
  end
end
