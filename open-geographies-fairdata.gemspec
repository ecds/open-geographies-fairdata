# frozen_string_literal: true

require_relative 'lib/open_geographies_fairdata/version'

Gem::Specification.new do |spec|
  spec.name        = 'open_geographies_fairdata'
  spec.version     = OpenGeographies::VERSION
  spec.authors     = ['Jay Varner']
  spec.email       = ['jayvarner@gmail.com']
  spec.homepage    = 'https://github.com/ecds/open-geographies-fairdata'
  spec.summary     = 'The Open Geographies canonical schema, v0/v1 API, and Elasticsearch indexing, for a FairData-based Core Data instance.'
  spec.description = 'Open Geographies engine for FairData (Core Data).'
  spec.license     = 'MIT'

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the "allowed_push_host"
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com'"

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = spec.homepage

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir['{app,config,db,lib}/**/*', 'MIT-LICENSE', 'Rakefile', 'README.md']
  end

  # aws-sdk-s3/aws-sdk-cloudfront: og_pmtiles.rake's own S3 upload + CDN
  # invalidation, moved here from core-data-cloud along with the task
  # itself - "any FairData-backed host gets PMTiles export for free" only
  # holds if this engine brings its own runtime dependencies rather than
  # assuming the host app happens to already have them bundled.
  spec.add_dependency('aws-sdk-cloudfront', '~> 1')
  spec.add_dependency('aws-sdk-s3', '~> 1')
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
