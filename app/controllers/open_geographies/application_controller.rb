# frozen_string_literal: true

module OpenGeographies
  class ApplicationController < ActionController::Base
    def index
      respond_501
    end

    def show
      respond_501
    end

    def create
      respond_501
    end

    def update
      respond_501
    end

    def destroy
      respond_501
    end

    private

    def respond_501
      render(json: { error: 'method not implemented' }, status: :not_implemented)
    end
  end
end
