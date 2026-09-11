# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Engine < ::Rails::Engine
      require 'rails/all'
      isolate_namespace CoreDataConnector::OpenGeographies

      # Without this, `rails db:migrate` in the host app never sees
      # db/migrate here at all - this engine had no migrations of its own
      # until ProjectModelRole, so nothing surfaced the gap before now.
      #
      # Guards against double-appending by checking the actual path, not by
      # comparing app.root to the engine's root - a root-path check breaks
      # for spec/dummy specifically, since it's nested *inside* this engine's
      # own repo, so app.root.to_s.match?(root.to_s) is true there for the
      # same reason it's true for any real host app that happens to check
      # out this gem locally - the string match can't tell "is the same app"
      # apart from "is a subdirectory of it".
      initializer :append_migrations do |app|
        config.paths['db/migrate'].expanded.each do |expanded_path|
          app.config.paths['db/migrate'] << expanded_path unless app.config.paths['db/migrate'].expanded.include?(expanded_path)
        end
      end

      # Reapplies on every boot and every Zeitwerk reload in development -
      # see Decorators' own header comment for why re-running this is safe
      # and necessary.
      config.to_prepare do
        ::CoreDataConnector::OpenGeographies::V1::Decorators.apply!
      end
    end
  end
end
