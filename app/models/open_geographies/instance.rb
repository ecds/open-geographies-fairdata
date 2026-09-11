# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Instance < ::CoreDataConnector::Instance
      include Searchable

      self.table_name = 'core_data_connector_instances'
    end
  end
end
