# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Person < ::CoreDataConnector::Person
      include Searchable

      self.table_name = 'core_data_connector_people'

      def search_data
        {
          first_name:,
          last_name:,
        }
      end

      private

      def name
        first_name + ' ' + last_name
      end
    end
  end
end
