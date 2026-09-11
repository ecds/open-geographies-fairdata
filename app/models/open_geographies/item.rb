# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Item < ::CoreDataConnector::Item
      include Searchable

      self.table_name = 'core_data_connector_items'
    end
  end
end
