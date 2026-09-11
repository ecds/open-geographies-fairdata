# frozen_string_literal: true

require_relative 'lib/core_data_connector_open_geographies/version'

Gem::Specification.new do |spec|
  spec.name        = 'core_data_connector_open_geographies'
  spec.version     = CoreDataConnector::OpenGeographies::VERSION
  spec.authors     = ['Jay Varner']
  spec.email       = ['jayvarner@gmail.com']
  spec.homepage    = 'https://github.com/ecds'
  spec.summary     = 'https://github.com/ecds'
  spec.description = 'OpenGeographies addon engine for CoreDataConnector.'
  spec.license     = 'MIT'

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the "allowed_push_host"
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com'"

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/ecds'
  spec.metadata['changelog_uri'] = 'https://github.com/ecds'

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir['{app,config,db,lib}/**/*', 'MIT-LICENSE', 'Rakefile', 'README.md']
  end

  spec.add_dependency('elasticsearch', '~> 8')
  spec.add_dependency('rails', '>= 8.0.2')
  spec.add_dependency('rgeo-geojson', '~> 2.2')
  spec.add_dependency('searchkick', '~> 5.4.0')
  spec.add_development_dependency('fuzzy_dates')
  spec.add_development_dependency('resource_api')
  spec.add_development_dependency('rspec-rails', '~> 8.0')
  spec.add_development_dependency('triple_eye_effable')
  spec.add_development_dependency('user_defined_fields')
  # CoreDataConnector itself is no longer a gem dependency - the dummy app
  # (spec/dummy) vendors it directly from a core-data-cloud checkout via
  # bin/sync_core_data_connector, since core-data-cloud's own copy diverged
  # from the last-published standalone gem tag. These two are what that
  # vendored code actually requires (confirmed via its own require/include
  # statements, not guessed): Auditable (used by most vendored models) needs
  # PaperTrail; Authority::* (constructed dynamically off WebIdentifier) needs
  # Http::Requestable's typhoeus dependency.
  spec.add_development_dependency('paper_trail', '>= 16.0')
  spec.add_development_dependency('typhoeus', '~> 1.6')
end
