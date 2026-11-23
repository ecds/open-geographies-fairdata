# frozen_string_literal: true

# TripleEyeEffable::Resourceable's before_create/before_update/before_destroy
# callbacks (included into MediaContent) call TripleEyeEffable::Cloud, a real
# HTTP client for the external object storage service. No test in this suite
# should depend on that service being up, so it's stubbed globally rather
# than per-factory - FactoryBot's own DSL blocks run outside RSpec's example
# context (FactoryBot::SyntaxRunner), so allow_any_instance_of isn't
# reachable from inside a factory definition at all.
RSpec.configure do |config|
  config.before do
    allow_any_instance_of(TripleEyeEffable::Cloud).to(receive(:save_resource))
    allow_any_instance_of(TripleEyeEffable::Cloud).to(receive(:delete_resource))
  end
end
