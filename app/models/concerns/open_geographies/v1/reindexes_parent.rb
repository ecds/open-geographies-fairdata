# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      # For records that aren't themselves indexed but whose change should
      # update a *parent* record's document - a PlaceGeometry or PlaceName
      # edit means the owning Place's search_data changed, even though
      # PlaceGeometry/PlaceName have no V1:: index of their own. Delegates
      # to Reindexable.reindex_record for the actual becomes()+reindex work
      # (same disable-guard and cold-index handling, applied to a named
      # association instead of self).
      module ReindexesParent
        extend ActiveSupport::Concern

        class_methods do
          # og_v1_reindexes(:place) / og_v1_reindexes(:primary_record, :related_record)
          def og_v1_reindexes(*associations)
            after_commit do
              associations.each do |assoc|
                parent = public_send(assoc)
                Reindexable.reindex_record(parent) if parent
              end
            end
          end
        end
      end
    end
  end
end
