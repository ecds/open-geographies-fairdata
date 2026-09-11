# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Taxonomy < ::CoreDataConnector::Taxonomy
      include Searchable

      self.table_name = 'core_data_connector_taxonomies'
    end
  end
end
