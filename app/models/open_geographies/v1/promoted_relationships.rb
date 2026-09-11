# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    module V1
      # The registry of which relationship names count as OG-compliant
      # promotions, derived directly from the canonical schema template
      # (og_schema/canonical_template.json) rather than hand-maintained a
      # second time in Ruby. That file already carries this information -
      # every relationship meant to promote already has an og.promote target
      # on it - and it's also what a future provisioning CLI would read to
      # *create* compliant structure in the first place. One file, two
      # readers, so they can't drift apart the way a flag-based mechanism
      # and the UI that sets it could.
      #
      # Exact match only, by design: "types" or "Type" (wrong case or
      # pluralization) does not count as the "Types" relationship. OG
      # compliance means using the documented name, not the indexer guessing
      # at what a curator probably meant - see the discussion that led here
      # for why a flag-based mechanism was ruled out (it would require
      # columns on ProjectModelRelationship/UserDefinedField in
      # core-data-connector, a repo this engine doesn't own and can't diverge
      # from indefinitely).
      module PromotedRelationships
        TEMPLATE_PATH = ::CoreDataConnector::OpenGeographies::Engine.root.join(
          'lib', 'core_data_connector_open_geographies', 'v1', 'canonical_template.json'
        )
        TEMPLATE = JSON.parse(File.read(TEMPLATE_PATH), symbolize_names: true).freeze

        # { "Places" => { "Types" => :types, "Contained In" => :contained_in_place, "Media" => :media, ... },
        #   "Works"  => { "Type" => :work_type },
        #   ... }
        BY_TEMPLATE_MODEL = TEMPLATE[:project_models].each_with_object({}) do |project_model, hash|
          relationships = project_model[:project_model_relationships] || []
          hash[project_model[:name].to_s] = relationships.each_with_object({}) do |rel, rel_hash|
            promote = rel.dig(:og, :promote)
            rel_hash[rel[:name].to_s] = promote.to_sym if promote
          end
        end.freeze

        # Same idea as BY_TEMPLATE_MODEL, but for scalar user_defined_fields
        # rather than relationships - e.g. Map Layers' "Date"/"Bearing" UDFs
        # promote to top-level "date"/"bearing"; "Source Type"/"Source URLs"
        # promote to the dotted path "source.type"/"source.urls", which
        # Searchable#user_defined_fields merges into one `source: {type:,
        # urls:}` object. Values stay as bare strings (not stored as
        # promote.to_sym), since dotted paths aren't valid symbols.
        # { "Map Layers" => { "Date" => "date", "Source Type" => "source.type", ... }, ... }
        BY_TEMPLATE_MODEL_UDFS = TEMPLATE[:project_models].each_with_object({}) do |project_model, hash|
          fields = project_model[:user_defined_fields] || []
          hash[project_model[:name].to_s] = fields.each_with_object({}) do |udf, udf_hash|
            promote = udf.dig(:og, :promote)
            udf_hash[udf[:column_name].to_s] = promote if promote
          end
        end.freeze

        # model_type is an index-layer concept (see og_schema/README.md's
        # authoring-vs-index split) - it doesn't live in the template, which
        # describes the authoring layer, so it's mapped here rather than
        # added as a new key to a file we don't unilaterally get to redesign.
        MODEL_TYPE_BY_TEMPLATE_MODEL = {
          'Places' => 'place',
          'Media' => 'media',
          'Works' => 'work',
          'People' => 'person',
          'Organizations' => 'organization',
          'Map Layers' => 'map_layer',
          'Types' => 'term',
          'Work Types' => 'term',
          'Tours' => 'tour',
        }.freeze

        # Unambiguous superclass -> template entry. CoreDataConnector::Place is
        # deliberately absent here - it's the one case that needs
        # ProjectModelRole, handled separately below.
        UNAMBIGUOUS_TEMPLATE_MODEL_BY_SUPERCLASS = {
          ::CoreDataConnector::MediaContent => 'Media',
          ::CoreDataConnector::Work => 'Works',
          ::CoreDataConnector::Person => 'People',
          ::CoreDataConnector::Organization => 'Organizations',
          ::CoreDataConnector::Instance => 'Tours',
          # Ambiguous with "Work Types", but neither has outgoing promoted
          # relationships, so the ambiguity isn't load-bearing today.
          ::CoreDataConnector::Taxonomy => 'Types',
        }.freeze

        class << self
          # Which canonical template entry applies to a given V1 record. Most
          # model classes are unambiguous. CoreDataConnector::Place is the one
          # exception - shared by "Places" and "Map Layers" - resolved via
          # ProjectModelRole rather than guessed at.
          #
          # Deliberately `==`, not a `case/when` on record.class.superclass:
          # `when SomeClass` tests `SomeClass === value`, which for a bare
          # Class literal means "is value an *instance* of SomeClass" - but
          # record.class.superclass is itself a Class, not an instance of
          # one, so every branch would silently and permanently fail to match.
          def template_model_name_for(record)
            superclass = record.class.superclass

            if superclass == ::CoreDataConnector::Place
              role = ::CoreDataConnector::OpenGeographies::ProjectModelRole
                .find_by(project_model_id: record.project_model_id)&.role
              role == 'map_layer' ? 'Map Layers' : 'Places'
            else
              UNAMBIGUOUS_TEMPLATE_MODEL_BY_SUPERCLASS[superclass]
            end
          end

          # { "Types" => :types, ... } for this specific record, or {} if its
          # template entry has no promoted relationships (or isn't
          # recognized - e.g. a model_class the template doesn't cover at all).
          def for(record)
            BY_TEMPLATE_MODEL[template_model_name_for(record)] || {}
          end

          # { "Date" => "date", "Source Type" => "source.type", ... } for
          # this specific record, or {} if its template entry has no
          # promoted UDFs.
          def udfs_for(record)
            BY_TEMPLATE_MODEL_UDFS[template_model_name_for(record)] || {}
          end

          def model_type_for(record)
            MODEL_TYPE_BY_TEMPLATE_MODEL[template_model_name_for(record)] || 'unknown'
          end
        end
      end
    end
  end
end
