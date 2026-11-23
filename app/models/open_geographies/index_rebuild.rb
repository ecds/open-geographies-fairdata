# frozen_string_literal: true

module OpenGeographies
  # A rebuild of a project's index in progress (V1::Indexes.rebuild): the
  # index being filled, which every write to the project also goes to, and a
  # log of records written meanwhile, which the rebuild reads again before the
  # swap. A row left by a rebuild whose process died is removed by the
  # project's next rebuild.
  class IndexRebuild < ApplicationRecord
    self.table_name = 'open_geographies_index_rebuilds'

    has_many :logged_changes, class_name: 'OpenGeographies::IndexRebuildChange', dependent: :delete_all

    validates :project_id, :index_name, presence: true

    # Logs records (V1 instances) written while this rebuild runs.
    def log!(records)
      return if records.empty?

      now = Time.current
      IndexRebuildChange.insert_all(records.map do |record|
        {
          index_rebuild_id: id,
          record_type: record.class.name,
          record_id: record.id,
          document_id: record.search_document_id.to_s,
          created_at: now,
        }
      end)
    end

    # Removes and returns the changes logged so far, as
    # [[record_type, record_id, document_id], ...]. Changes logged while this
    # runs are left for the next call.
    def consume_changes!
      sql = self.class.sanitize_sql([<<~SQL.squish, id])
        DELETE FROM #{IndexRebuildChange.table_name} WHERE index_rebuild_id = ?
        RETURNING record_type, record_id, document_id
      SQL

      # Not cached, since the same statement returns different rows each time.
      self.class.uncached { self.class.connection.select_rows(sql) }
    end
  end
end
