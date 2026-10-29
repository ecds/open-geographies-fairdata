# frozen_string_literal: true

module OpenGeographies
  module V1
    class ApplicationController < ::OpenGeographies::ApplicationController
      before_action :require_project, if: -> { Indexes.per_project? }

      # A project whose own index is not built yet has nothing to search:
      # places#index returns an empty page, other lists an empty array, and
      # a single record is not found.
      rescue_from Searchkick::MissingIndexError do
        if action_name == 'index' && controller_name == 'places'
          render(json: { results: [], meta: { page: 1, per_page: 0, total_count: 0, total_pages: 0 }, facets: {} })
        elsif action_name == 'index'
          render(json: [])
        else
          render(json: {}, status: :not_found)
        end
      end

      private

      # The index to search: the project's own under OG_INDEX_LAYOUT=per_project,
      # otherwise the shared one. Queries keep their project_id filter either way.
      def search_index_name
        project_id ? Indexes.name_for(project_id) : Place.searchkick_index.name
      end

      # Under per_project there is no index to search without a project.
      def require_project
        render(json: {}, status: :not_found) unless project_id
      end

      # Resolves the project slug in the URL (a parameterized project name,
      # such as "my-project") to a Project id. Only discoverable projects are
      # considered, so a project that is not discoverable cannot be reached
      # through this API even if its slug is known. Every v1 controller uses
      # this method so the check is made in one place. Project has no slug
      # column, so each project's name is parameterized and compared.
      def project_id
        @project_id ||= ::CoreDataConnector::Project.where(discoverable: true).to_a.find { |p| p.name.parameterize == params[:project] }&.id
      end
    end
  end
end
