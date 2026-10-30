# frozen_string_literal: true

module CoreDataConnector
  class RecordMerge < ApplicationRecord
    belongs_to :mergeable, polymorphic: true
  end
end
