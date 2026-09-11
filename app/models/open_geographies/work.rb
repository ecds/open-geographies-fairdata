# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Work < ::CoreDataConnector::Work
      include Searchable

      self.table_name = 'core_data_connector_works'

      private

      def extras
        user_defined_fields
      end
    end
  end
end
