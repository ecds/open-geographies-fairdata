# frozen_string_literal: true

module OpenGeographies
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
