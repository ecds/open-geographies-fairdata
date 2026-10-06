# frozen_string_literal: true

module OpenGeographies
  module V1
    class Person < ::CoreDataConnector::Person
      include Searchable

      searchable_index 'open_geographies_v1'

      self.table_name = 'core_data_connector_people'

      # Adds first_name and last_name to the standard document, since
      # Nameable's `name` delegate does not expose them separately.
      def extras
        { first_name:, last_name: }
      end

      def name
        [first_name, last_name].compact.join(' ')
      end
    end
  end
end
