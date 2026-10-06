# frozen_string_literal: true

module OpenGeographies
  module V1
    class ApplicationController < ::OpenGeographies::ApplicationController
      private

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
