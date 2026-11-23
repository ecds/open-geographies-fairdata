# frozen_string_literal: true

module OpenGeographies
  module V1
    # Builds a project's index in full when a write under
    # OG_INDEX_LAYOUT=per_project finds it missing (Indexes#write).
    class RebuildIndexJob < ::OpenGeographies::ApplicationJob
      def perform(project_id)
        Indexes.ensure_built!(project_id)
      end
    end
  end
end
