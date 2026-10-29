# frozen_string_literal: true

module OpenGeographies
  # A record written while its project's index was being rebuilt (see IndexRebuild).
  class IndexRebuildChange < ApplicationRecord
    self.table_name = 'open_geographies_index_rebuild_changes'

    belongs_to :index_rebuild, class_name: 'OpenGeographies::IndexRebuild'
  end
end
