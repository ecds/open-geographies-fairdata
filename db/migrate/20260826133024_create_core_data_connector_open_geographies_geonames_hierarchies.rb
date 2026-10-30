# frozen_string_literal: true

class CreateCoreDataConnectorOpenGeographiesGeonamesHierarchies < ActiveRecord::Migration[7.1]
  def change
    create_table(:core_data_connector_open_geographies_geonames_hierarchies) do |t|
      t.bigint(:place_id, null: false)
      t.decimal(:lat, precision: 10, scale: 6, null: false)
      t.decimal(:lng, precision: 10, scale: 6, null: false)
      t.jsonb(:hierarchy, null: false, default: [])
      t.datetime(:fetched_at, null: false)

      t.timestamps
    end

    add_index(
      :core_data_connector_open_geographies_geonames_hierarchies,
      :place_id,
      unique: true,
      name: 'index_og_geonames_hierarchies_on_place_id',
    )
  end
end
