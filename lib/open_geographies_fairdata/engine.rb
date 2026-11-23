# frozen_string_literal: true

module OpenGeographies
  class Engine < ::Rails::Engine
    require 'rails/all'
    isolate_namespace OpenGeographies

    # Rails discovers this engine's db/migrate and lib/tasks/*.rake on its own,
    # so no initializer is needed to append migrations or load rake tasks.
    # Adding either by hand registers them twice: migrations then fail with
    # "Duplicate migration", and rake tasks run their body twice per invocation.

    # Runs on every boot and on every Zeitwerk reload in development. See the
    # header comment in Decorators for why re-applying is safe and necessary.
    config.to_prepare do
      ::OpenGeographies::V1::Decorators.apply!
    end
  end
end
