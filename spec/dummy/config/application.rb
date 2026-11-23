# frozen_string_literal: true

require_relative 'boot'

require 'rails/all'

# Vendored from core-data-cloud (see bin/sync_core_data_connector) - must be
# required explicitly, before Zeitwerk ever touches the CoreDataConnector
# constant. app/models/core_data_connector/ is itself a directory, so
# Zeitwerk auto-vivifies an empty CoreDataConnector namespace module the
# first time any model under it loads; without this explicit require running
# first, that auto-vivified module wins and lib/core_data_connector.rb's
# `self.table_name_prefix` (every vendored model relies on this to resolve
# to "core_data_connector_places" instead of the bare, wrong "places") never
# gets defined at all - core-data-cloud's own config/application.rb requires
# it the same way, for the same reason.
require_relative '../lib/core_data_connector'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Dummy
  class Application < Rails::Application
    config.load_defaults(Rails::VERSION::STRING.to_f)

    # For compatibility with applications that use this config
    config.action_controller.include_all_helpers = false

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: ['assets', 'tasks'])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
