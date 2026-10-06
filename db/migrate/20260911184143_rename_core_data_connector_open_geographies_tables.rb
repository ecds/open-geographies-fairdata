# frozen_string_literal: true

# Renames this engine's two tables to drop the "core_data_connector_" prefix,
# matching the OpenGeographies module name. The tables were never part of
# core-data-connector.
#
# rename_table is used instead of drop and recreate because it is a metadata
# change that keeps existing rows. That includes cached GeoNames lookups,
# which a recreated table would have to fetch from the GeoNames API again.
class RenameCoreDataConnectorOpenGeographiesTables < ActiveRecord::Migration[8.1]
  def change
    rename_table :core_data_connector_open_geographies_project_model_roles,
      :open_geographies_project_model_roles

    rename_table :core_data_connector_open_geographies_geonames_hierarchies,
      :open_geographies_geonames_hierarchies
  end
end
