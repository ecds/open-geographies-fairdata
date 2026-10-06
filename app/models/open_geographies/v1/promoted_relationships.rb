# frozen_string_literal: true

module OpenGeographies
  module V1
    # The registry of which relationship names count as promotions, derived
    # from the canonical schema template (lib/open_geographies_fairdata/v1/
    # canonical_template.json) and not maintained a second time in Ruby. Every
    # relationship that promotes has an og.promote target in that file, which
    # is also what a provisioning tool would read to create the structure, so
    # both read the same source.
    #
    # Matching is exact by design: "types" or "Type" (wrong case or plural)
    # does not count as the "Types" relationship. A compliant atlas uses the
    # documented name, and the indexer does not guess. A database flag was not
    # used because it would need new columns on ProjectModelRelationship and
    # UserDefinedField in core-data-connector, which this engine does not own.
    module PromotedRelationships
      TEMPLATE_PATH = ::OpenGeographies::Engine.root.join(
        'lib', 'open_geographies_fairdata', 'v1', 'canonical_template.json'
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

      # Like BY_TEMPLATE_MODEL, but for scalar user_defined_fields. For example
      # Map Layers' "Date" and "Bearing" fields promote to top-level "date" and
      # "bearing", and "Source Type" and "Source URLs" promote to the dotted
      # paths "source.type" and "source.urls", which
      # Searchable#user_defined_fields merges into one `source: {type:, urls:}`
      # object. Values are kept as strings and not converted with
      # promote.to_sym, since dotted paths are not valid symbols.
      # { "Map Layers" => { "Date" => "date", "Source Type" => "source.type", ... }, ... }
      BY_TEMPLATE_MODEL_UDFS = TEMPLATE[:project_models].each_with_object({}) do |project_model, hash|
        fields = project_model[:user_defined_fields] || []
        hash[project_model[:name].to_s] = fields.each_with_object({}) do |udf, udf_hash|
          promote = udf.dig(:og, :promote)
          udf_hash[udf[:column_name].to_s] = promote if promote
        end
      end.freeze

      # model_type belongs to the index layer. The template describes the
      # authoring layer, so it is mapped here and not added to the template.
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

      # Template entry for each superclass that maps to exactly one. Place is
      # left out because it is shared by "Places" and "Map Layers" and is
      # resolved through ProjectModelRole instead.
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
        # Compares with `==` and not `case/when`. `when SomeClass` tests
        # `SomeClass === value`, which for a class literal checks whether the value
        # is an instance of it, and record.class.superclass is a Class and not an
        # instance, so no branch would ever match.
        def template_model_name_for(record)
          superclass = record.class.superclass

          if superclass == ::CoreDataConnector::Place
            role = ::OpenGeographies::ProjectModelRole
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
