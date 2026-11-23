# frozen_string_literal: true

class CreateOpenGeographiesIndexRebuilds < ActiveRecord::Migration[7.1]
  def change
    create_table(:open_geographies_index_rebuilds) do |t|
      t.bigint(:project_id, null: false)
      t.string(:index_name, null: false)

      t.timestamps
    end

    add_index(:open_geographies_index_rebuilds, :project_id)
    add_index(:open_geographies_index_rebuilds, :index_name, unique: true)

    create_table(:open_geographies_index_rebuild_changes) do |t|
      t.references(
        :index_rebuild,
        null: false,
        index: true,
        foreign_key: { to_table: :open_geographies_index_rebuilds, on_delete: :cascade },
      )
      t.string(:record_type, null: false)
      t.bigint(:record_id, null: false)
      t.string(:document_id, null: false)
      t.datetime(:created_at, null: false)
    end
  end
end
