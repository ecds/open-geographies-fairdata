# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      class Item < ::CoreDataConnector::Item
        include Searchable

        searchable_index 'open_geographies_v1'

        self.table_name = 'core_data_connector_items'
      end
    end
  end
end
