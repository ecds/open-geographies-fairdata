# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in core-data-connector-ecds.gemspec.
gemspec

# The gemspec's own '>= 8.0.2' floor let Bundler resolve 8.1.1, which has a
# real incompatibility with activerecord-postgis-adapter 11.1.1's
# lookup_cast_type override (NoMethodError: undefined method 'lookup' for
# nil, on any add_column with a default - found live, vendoring
# CoreDataConnector's own migrations). core-data-cloud pins '~> 8.1.3' with
# the same postgis-adapter version and doesn't hit this - matching that
# pin here instead of chasing a workaround for what's really just a
# resolved-version gap.
gem 'rails', '~> 8.1.3'

gem 'puma'

gem 'propshaft'

# Resource API
gem 'resource_api', git: 'https://github.com/performant-software/resource-api.git', tag: 'v0.5.15'

# IIIF
gem 'triple_eye_effable', git: 'https://github.com/performant-software/triple-eye-effable.git', tag: 'v0.2.11'

# User defined fields
gem 'user_defined_fields', git: 'https://github.com/performant-software/user-defined-fields.git', tag: 'v0.1.14'

# Fuzzy dates
gem 'fuzzy_dates', git: 'https://github.com/performant-software/fuzzy-dates.git', tag: 'v0.1.2'

# Vendored CoreDataConnector (spec/dummy/app/models/core_data_connector,
# synced from core-data-cloud via bin/sync_core_data_connector) needs these
# two directly - declaring them only via add_development_dependency in the
# gemspec, like every other dependency below, doesn't get them into
# Bundler.require(*Rails.groups)'s :default group, so Auditable's
# has_paper_trail call and Authority::*'s typhoeus requests silently never
# loaded until these explicit lines were added.
gem 'paper_trail', '>= 16.0'
gem 'typhoeus', '~> 1.6'

# Elasticsearch
gem 'elasticsearch', '~> 8.0'
gem 'faraday-typhoeus', '~> 1.0' # Needed to use Elasticsearch in rake tasks.
gem 'searchkick'

# Geospatial libraries
gem 'aws-sdk'
gem 'concurrent-ruby', '1.3.4'
gem 'rgeo', '~> 3.0'
gem 'rgeo-geojson', '~> 2.2'
# spec/dummy/config/database.yml has always requested adapter: postgis, but
# this gem was never added - a pre-existing gap that only surfaces on a real
# db:drop/db:create cycle. Pinned to match core-data-cloud's own version.
gem 'activerecord-postgis-adapter', '~> 11.1'

group :development, :test do
  gem 'bcrypt', '~> 3.1.22'
  gem 'csv', '~> 3.3.5'
  gem 'database_cleaner'
  gem 'factory_bot_rails'
  gem 'faker'
  gem 'jwt_auth', git: 'https://github.com/performant-software/jwt-auth.git', tag: 'v0.1.3'
  gem 'pg', '~> 1.5.9'
  gem 'roo', '~> 2.10.0'
  gem 'rspec-rails', '~> 8.0' # Use an appropriate version, check RSpec documentation
  gem 'rubocop-shopify'
  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem 'rubocop-rails-omakase', require: false
end
