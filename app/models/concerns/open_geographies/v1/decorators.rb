# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      # Wires Reindexable/ReindexesParent onto the upstream base classes at
      # boot - applied from Engine's `config.to_prepare` so it re-applies
      # after every Zeitwerk reload in development (each reload hands out a
      # fresh class object, so a previous run's #include calls are gone).
      # Guarded by `unless model.include?(...)` so re-running within one
      # process is a no-op, not a double-registration.
      module Decorators
        # Every model V1::Searchable's `searchable_index` is actually called
        # on today. MapLayer is deliberately excluded - see Reindexable's own
        # header comment on why a Place-class MapLayer record isn't handled
        # by this mechanism yet.
        REINDEXED_MODELS = [
          'Event', 'Instance', 'Item', 'MediaContent', 'Organization', 'Person', 'Place', 'Taxonomy', 'Work',
        ].freeze

        # Nested records with no V1:: index of their own, whose change should
        # still reindex the named parent association(s).
        NESTED_REINDEXERS = {
          'CoreDataConnector::PlaceGeometry' => [:place],
          'CoreDataConnector::PlaceName' => [:place],
          'CoreDataConnector::Relationship' => [:primary_record, :related_record],
        }.freeze

        class << self
          def apply!
            REINDEXED_MODELS.each do |name|
              model = "CoreDataConnector::#{name}".constantize
              model.include(Reindexable) unless model.include?(Reindexable)
            end

            NESTED_REINDEXERS.each do |name, associations|
              model = name.constantize
              next if model.include?(ReindexesParent)

              model.include(ReindexesParent)
              model.og_v1_reindexes(*associations)
            end
          end
        end
      end
    end
  end
end
