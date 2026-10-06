# frozen_string_literal: true

# Lives entirely in this engine's own schema - references
# core_data_connector_project_models (and, denormalized, core_data_connector_
# projects) by plain id, not something added to core-data-connector's own
# tables/migrations. That's deliberate: this engine is a fork of a repo we
# don't own, and adding columns there would be permanent divergence with no
# way back. This table is how v1 answers "which role does this project_model
# play" (the primary Place model when an atlas has several; which Place-class
# models are actually Map Layers) without touching anything upstream.
class CreateCoreDataConnectorOpenGeographiesProjectModelRoles < ActiveRecord::Migration[7.1]
  def change
    create_table :core_data_connector_open_geographies_project_model_roles do |t|
      t.bigint :project_model_id, null: false
      # Denormalized from project_model.project_id, set by the model - needed
      # because the invariant that actually matters ("only one primary place
      # model per project") spans project_models, and a DB-level partial
      # unique index can't reach across a join to enforce that; it can only
      # constrain columns that live on this table.
      t.bigint :project_id, null: false
      t.string :role, null: false

      t.timestamps
    end

    add_index :core_data_connector_open_geographies_project_model_roles,
      :project_model_id, name: 'index_og_project_model_roles_on_project_model_id'

    add_index :core_data_connector_open_geographies_project_model_roles,
      :project_id,
      unique: true,
      where: "role = 'primary_place'",
      name: 'index_og_project_model_roles_on_unique_primary_place'

    # "map_layer" is intentionally not unique per project: an atlas can tag
    # more than one Place-class project_model as a map layer source (for
    # example separate map and topo quad models), and all of them are indexed
    # under the same model_type.
    add_index :core_data_connector_open_geographies_project_model_roles,
      [:project_model_id, :role], unique: true,
      name: 'index_og_project_model_roles_on_project_model_id_and_role'
  end
end
