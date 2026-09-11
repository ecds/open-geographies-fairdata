# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      class Work < ::CoreDataConnector::Work
        include Searchable

        searchable_index 'open_geographies_v1'

        self.table_name = 'core_data_connector_works'
      end
    end
  end
end
