# frozen_string_literal: true

require 'factory_bot_rails'
require 'faker'

3.times do
  project = FactoryBot.create(:project)
  project_model = CoreDataConnector::ProjectModel.create(name: 'Places', project:, model_class: 'CoreDataConnector::Place')
  5.times do
    place_name = FactoryBot.build(:place_name, primary: true)
    place = FactoryBot.build(:place, project_model:)
    place.place_names << place_name
    place.save
    FactoryBot.create(:place_geometry, place:)
  end
end

OpenGeographies::Place.reindex
