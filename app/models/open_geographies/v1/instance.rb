# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      class Instance < ::CoreDataConnector::Instance
        include Searchable

        searchable_index 'open_geographies_v1'

        self.table_name = 'core_data_connector_instances'
      end
    end
  end
end
