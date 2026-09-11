# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Organization < ::CoreDataConnector::Organization
      include Searchable

      self.table_name = 'core_data_connector_organizations'
    end
  end
end
