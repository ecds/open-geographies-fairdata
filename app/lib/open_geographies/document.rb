# frozen_string_literal: true

module CoreDataConnector
  module OpenGeographies
    class Document
      def initialize(record, related = false)
        @record = record
        @related = related
      end

      def document
        {
          id: @record.id,
          uuid: @record.uuid,
          name: @record.name,
          slug: @record.name.parameterize,
          **user_defined,
          **extras,
          **related,
          **related_to,
        }
      end

      private

      def part_of_rel_model
        CoreDataConnector::ProjectModelRelationship.find(
          related_model: @record.project_model,
          inverse_name: 'Part of',
        )
      end

      def parent
        CoreDataConnector::Relationship.find_by(
          project_model_relationship: part_of_rel_model,
          related_record: @record,
        ).primary_record
      end

      def slug
        place_names = CoreDataConnector::PlaceName.where(name: @record.name)
        place_names.filter! { |pn| pn.place.project_model == @record.project_model }
        return @record.name.parameterize if place_names.count == 1

        parent_rels_count = place_names.map do |pn|
          CoreDataConnector::Relationship.where(
            project_model_relationship: part_of_rel_model,
            primary_record: parent,
            related_record: pn.place,
          ).count
        end

        return "#{@record.name} #{parent.name} #{@record.id}".parameterize if parent_rels_count > 1

        "#{@record.name} #{parent.name}".parameterize
      end

      def user_defined(record = @record)
        attributes = {}

        user_defined_fields = case record.class.name
        when 'CoreDataConnector::Relationship'
          record.project_model_relationship.user_defined_fields
        else
          record.project_model.user_defined_fields
        end

        record.user_defined.each do |key, value|
          user_defined_field = user_defined_fields.find_by(uuid: key)
          next if user_defined_field.nil?

          label = user_defined_field.column_name
          attributes[label.parameterize.underscore.to_sym] = { label:, value: }
        end

        attributes
      end

      def related(record = @record)
        related_records = {}

        return related_records if @related

        relations = CoreDataConnector::ProjectModelRelationship.where(primary_model: record.project_model)

        relations.each do |rel|
          if rel.multiple
            records = CoreDataConnector::Relationship.where(project_model_relationship: rel, primary_record: record)
            next if records.empty?

            related_records[rel.name.parameterize.underscore.to_sym] = records.map do |rel_record|
              rel_doc = CoreDataConnector::OpenGeographies::Document.new(rel_record.related_record, true)
              { **rel_doc.document, **user_defined(rel_record) }
            end
          else
            rel_record = CoreDataConnector::Relationship.find_by(project_model_relationship: rel, primary_record: record)
            next if rel_record.nil?

            rel_record = rel_record.related_record
            rel_doc = CoreDataConnector::OpenGeographies::Document.new(rel_record, true)
            related_records[rel.name.parameterize.underscore.to_sym] = rel_doc.document
          end
        end

        related_records
      end

      def related_to(record = @record)
        related_records = {}

        return related_records if @related

        relations = CoreDataConnector::ProjectModelRelationship.where(related_model: record.project_model)

        relations.each do |rel|
          next unless rel.allow_inverse

          if rel.multiple
            records = CoreDataConnector::Relationship.where(project_model_relationship: rel, related_record: record).map(&:primary_record)
            next if records.empty?

            related_records[rel.inverse_name.parameterize.underscore.to_sym] = records.map do |rel_record|
              rel_doc = CoreDataConnector::OpenGeographies::Document.new(rel_record, true)
              rel_doc.document
            end
          else
            rel_record = CoreDataConnector::Relationship.find_by(project_model_relationship: rel, related_record: record)
            next if rel_record.nil?

            rel_record = rel_record.primary_record
            rel_doc = CoreDataConnector::OpenGeographies::Document.new(rel_record, true)
            related_records[rel.inverse_name.parameterize.underscore.to_sym] = rel_doc.document
          end
        end

        related_records
      end

      def extras
        case @record.class.name
        when 'CoreDataConnector::Place'
          {
            geometry: @record.place_geometry.to_geojson,
          }
        when 'CoreDataConnector::MediaContent'
          {
            preview: @record.resource_description.content_preview_url,
            thumbnail: @record.resource_description.content_thumbnail_url,
            full: @record.resource_description.content_iiif_url,
            manifest: @record.manifest_url,
          }
        end
      end
    end
  end
end
