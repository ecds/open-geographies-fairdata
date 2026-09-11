# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    # Which role a project_model plays for OG indexing purposes, when that
    # can't be determined from model_class alone. Most model classes are
    # unambiguous (CoreDataConnector::Work always means the canonical "Works"
    # concept); CoreDataConnector::Place is shared by the real "Places" model
    # and by "Map Layers"/"Topo Quads" (both need PlaceLayer/PlaceGeometry,
    # which are hard-FK'd to Place in core-data-connector - not a modeling
    # choice we can avoid). This table is what tells V1::Searchable which is
    # which. See PromotedRelationships.template_model_name_for.
    class ProjectModelRole < ApplicationRecord
      self.table_name = 'core_data_connector_open_geographies_project_model_roles'

      ROLES = %w[primary_place map_layer].freeze

      validates :project_model_id, presence: true
      validates :role, presence: true, inclusion: { in: ROLES }
      validates :project_model_id, uniqueness: { scope: :role }

      before_validation :set_project_id, on: :create

      def project_model
        ::CoreDataConnector::ProjectModel.find(project_model_id)
      end

      private

      def set_project_id
        self.project_id ||= project_model&.project_id
      end
    end
  end
end
