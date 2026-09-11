# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      class ApplicationController < ::CoreDataConnector::OpenGeographies::ApplicationController
        private

        # Resolves the URL's parameterized project slug (e.g.
        # "historic-rural-churches-of-georgia") to a real Project id, scoped
        # to discoverable projects only - a non-discoverable project (draft,
        # unpublished, or explicitly hidden) is invisible to this public API
        # regardless of whether its slug is guessed correctly. Shared by
        # every v1 controller rather than each resolving/filtering this
        # independently, so there's exactly one place this enforcement can
        # be forgotten from. CoreDataConnector::Project has no dedicated slug
        # column - see PlacesController's original version of this method,
        # now consolidated here.
        def project_id
          @project_id ||= ::CoreDataConnector::Project.where(discoverable: true).to_a.find { |p| p.name.parameterize == params[:project] }&.id
        end
      end
    end
  end
end
