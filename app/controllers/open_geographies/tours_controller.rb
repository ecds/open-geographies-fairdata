# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class ToursController < ApplicationController
      def show
        @record = Tour.search('*', where: { slugs: params[:slug], project: params[:project] }, limit: 1, load: false).first
        render(json: @record, status: :ok) and return if @record

        render(json: {}, status: :not_found) if @record.nil?
      end
    end
  end
end
