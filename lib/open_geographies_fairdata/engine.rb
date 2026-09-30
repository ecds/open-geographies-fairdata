# frozen_string_literal: true

module OpenGeographies
  class Engine < ::Rails::Engine
    require 'rails/all'
    isolate_namespace OpenGeographies

    # No manual `initializer :append_migrations` here (a prior version of
    # this file had one, with a comment claiming it was required) - Rails
    # already auto-discovers every Railtie/Engine's own db/migrate via
    # Rails::Application#migration_railties, confirmed directly
    # (`Rails.application.migration_railties` lists OpenGeographies::Engine
    # with this engine's real db/migrate path, unprompted). The manual
    # append was pure redundancy with that built-in mechanism - and the
    # redundancy was actively harmful, not just superfluous: db:schema:load
    # (ActiveRecord::Schema.define -> assume_migrated_upto_version) ends up
    # combining both sources' contributions into one migrations_paths list
    # with this engine's path present twice, which reads as two distinct
    # migrations sharing the same version number and raises "Duplicate
    # migration". Never caught before because spec/dummy is the only
    # consumer of this engine's own db/migrate at all (a real host app has
    # no migrations there to begin with) and this is the first time this
    # engine's spec suite has actually been run against live Postgres+ES
    # rather than failing to connect before reaching this code at all.

    # No manual `rake_tasks do ... end` here either, for the exact same
    # reason - a version of this file briefly had one (added when og_pmtiles.rake
    # moved here from core-data-cloud, since `rake -T` inside this engine's
    # own spec/dummy found nothing for it without one). That test was
    # misleading: spec/dummy doesn't consume this engine as a real bundled
    # gem dependency, so it doesn't exercise Rails::Engine's own default
    # lib/tasks/*.rake discovery, which - confirmed directly by tracing
    # Rake::Task#enhance's actual call sites from core-data-cloud, the real
    # host app - DOES already find and load it on its own. The manual block
    # was pure redundancy with that, invisible in spec/dummy but real
    # anywhere this engine is consumed normally: both the built-in discovery
    # and the manual block loaded the same file, appending two actions to
    # one Rake::Task, so `og_pmtiles:create` silently ran its entire body -
    # full geometry export, tippecanoe build, S3 upload, CloudFront
    # invalidation - twice per invocation. Found live: two real S3 uploads,
    # two real CloudFront invalidations, from one command.

    # Reapplies on every boot and every Zeitwerk reload in development -
    # see Decorators' own header comment for why re-running this is safe
    # and necessary.
    config.to_prepare do
      ::OpenGeographies::V1::Decorators.apply!
    end
  end
end
