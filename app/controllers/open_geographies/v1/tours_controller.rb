# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      class ToursController < ApplicationController
        # CoreDataConnector::Instance, not a differently-named "Tour" - the
        # "Tours" project model's underlying AR class really is Instance
        # (schema.org ItemList/TouristTrip predates the OG naming), and
        # #related_class (Searchable) always resolves a relationship's
        # polymorphic type string to V1::<the real AR class's own name>, so
        # V1::Instance is the only name the generic relationship-traversal
        # machinery could ever actually construct for one - matching that,
        # rather than introducing a same-purpose "V1::Tour" class the
        # traversal path could never reach, is what keeps a Tour resolved
        # this way (e.g. a Place's inverse "Tours" relationship) and a Tour
        # resolved directly here the same class, producing the same shape.
        def show
          @record = Instance.search(
            '*',
            where: { model_type: 'tour', project_id: project_id, slugs: params[:slug] },
            limit: 1,
            load: false,
          ).first
          render(json: @record, status: :ok) and return if @record

          render(json: {}, status: :not_found)
        end
      end
    end
  end
end
