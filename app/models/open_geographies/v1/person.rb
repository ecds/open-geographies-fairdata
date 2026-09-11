# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      class Person < ::CoreDataConnector::Person
        include Searchable

        searchable_index 'open_geographies_v1'

        self.table_name = 'core_data_connector_people'

        # v0's Person#search_data fully overrides the concern's version (just
        # `{first_name:, last_name:}` - no uuid, no slug, no relationships at
        # all), which looks like an oversight rather than a deliberate
        # choice. Not carried forward here: this keeps the standard envelope
        # and just adds the two fields Nameable's `name` delegate doesn't
        # otherwise expose.
        def extras
          { first_name:, last_name: }
        end

        def name
          [first_name, last_name].compact.join(' ')
        end
      end
    end
  end
end
