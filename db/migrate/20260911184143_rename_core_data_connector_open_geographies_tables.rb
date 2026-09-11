# frozen_string_literal: true

# Drops the leftover "core_data_connector_" prefix from this engine's own two
# tables, matching the Ruby namespace rename (CoreDataConnector::OpenGeographies
# -> OpenGeographies) - these tables were never core-data-connector's own (see
# the original CreateCoreDataConnectorOpenGeographiesProjectModelRoles/
# ...GeonamesHierarchies migrations' own comments), so the prefix was always
# just an artifact of the old module nesting, not a real ownership marker.
#
# rename_table, not drop+recreate: core_data_connector_open_geographies_geonames_hierarchies
# holds 842 real cached rows in production (checked directly) - an instant,
# lossless Postgres metadata operation preserves them, where a drop+recreate
# would just force every one of those places to re-hit the live GeoNames API
# on the next reindex for no reason. project_model_roles is empty in
# production today, but there's no reason to treat it differently.
class RenameCoreDataConnectorOpenGeographiesTables < ActiveRecord::Migration[8.1]
  def change
    rename_table :core_data_connector_open_geographies_project_model_roles,
      :open_geographies_project_model_roles

    rename_table :core_data_connector_open_geographies_geonames_hierarchies,
      :open_geographies_geonames_hierarchies
  end
end
