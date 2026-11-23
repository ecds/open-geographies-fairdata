# frozen_string_literal: true

require 'searchkick'

timeout = 10

Searchkick.client = if ENV.fetch('RAILS_ENV', nil) == 'production'
  Elasticsearch::Client.new(
    host: 'https://search.ecds.io',
    api_key: Rails.application.credentials.dig(:rdsProduction, :es_api_key),
    transport_options: { request: { timeout: }, headers: { content_type: 'application/json' } },
    retry_on_failure: 2,
  )

else
  Elasticsearch::Client.new(
    host: 'localhost',
    transport_options: { request: { timeout: }, headers: { content_type: 'application/json' } },
  )
end
