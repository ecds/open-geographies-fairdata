# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Event < ::CoreDataConnector::Event
      include Searchable

      self.table_name = 'core_data_connector_events'
    end
  end
end
