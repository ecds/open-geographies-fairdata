# frozen_string_literal: true

require 'searchkick'

module ::CoreDataConnector
  module OpenGeographies
    module Searchable
      extend ActiveSupport::Concern

      included do
        searchkick deep_paging: true,
          callbacks: false,
          index_name: -> { name.pluralize.parameterize(separator: '_') }
      end

      def search_data
        {
          **user_defined_fields,
          **extras,
          **related,
          **related_to,
          **base_search_data,
        }
      end

      def base_search_data
        {
          id:,
          uuid:,
          name:,
          slug:,
          slugs:,
          project: project.name.parameterize,
          class_name: self.class.name,
          featured: featured,
        }
      end

      def related_search_data(order = nil)
        {
          order:,
          **extras,
          **related,
          **base_search_data,
        }
      end

      # private

      def part_of_rel_model
        ::CoreDataConnector::ProjectModelRelationship.where(
          related_model: project_model,
        )
      end

      def parent
        ::CoreDataConnector::Relationship.find_by(
          project_model_relationship: part_of_rel_model,
          related_record: self,
        ).primary_record
      end

      def slug
        ud_slug = project_model.user_defined_fields.find do |ud|
          ud.column_name.downcase.include?('slug')
        end
        ud_slug.nil? ? name.parameterize : user_defined[ud_slug.uuid]
      end

      def slugs
        ud_slugs = project_model.user_defined_fields.filter do |ud|
          ud.column_name.downcase.include?('slug')
        end.map { |ud| user_defined[ud.uuid] }

        comp_slugs = case self.class.name
        when 'CoreDataConnector::OpenGeographies::Place'
          place_names.map { |pn| pn.name.parameterize }
        when 'CoreDataConnector::OpenGeographies::Person'
          person_names.map do |pn|
            [pn.first_name, pn.middle_name, pn.last_name].join(' ').parameterize
          end
        else
          [name.parameterize]
        end

        [*ud_slugs, *comp_slugs].compact.uniq
      end

      def user_defined_fields(record = self)
        return {} if record.user_defined.nil?

        fields = case record.class.name
        when '::CoreDataConnector::Relationship'
          record.project_model_relationship.user_defined_fields
        else
          record.project_model.user_defined_fields
        end

        attributes = {}
        record.user_defined.each do |key, value|
          user_defined_field = fields.find_by(uuid: key)
          next if user_defined_field.nil?

          label = user_defined_field.column_name
          attributes[label.parameterize.underscore.to_sym] = { label:, value: }
        end

        attributes
      end

      def related
        related_records = {}

        relations = ::CoreDataConnector::ProjectModelRelationship.where(primary_model: project_model)

        relations.each_with_index do |rel, _idx|
          next if rel.name == 'County'

          if rel.multiple
            records = ::CoreDataConnector::Relationship.where(project_model_relationship: rel, primary_record: self)
            next if records.empty?

            related_records[rel.name.parameterize.underscore.to_sym] = records.map do |relation|
              related_class(relation.related_record_type).find(
                relation.related_record.id,
              ).related_search_data(relation.order)
            end
          else
            relation = ::CoreDataConnector::Relationship.find_by(project_model_relationship: rel, primary_record: self)
            next if relation.nil?

            related_records[rel.name.parameterize.underscore.to_sym] = related_class(
              relation.related_record_type,
            ).find(relation.related_record_id).related_search_data
          end
        end

        related_records
      end

      def related_to
        related_records = {}

        return related_records if @related

        relations = ::CoreDataConnector::ProjectModelRelationship.where(related_model: project_model)

        relations.each do |rel|
          next unless rel.allow_inverse

          if rel.multiple
            records = ::CoreDataConnector::Relationship.where(project_model_relationship: rel, related_record: self)
            next if records.empty?

            related_records[rel.inverse_name.parameterize.underscore.to_sym] = records.map do |relation|
              related_class(relation.primary_record_type).find(
                relation.primary_record.id,
              ).base_search_data
            end

          else
            relation = ::CoreDataConnector::Relationship.find_by(project_model_relationship: rel, related_record: self)
            next if relation.nil?

            related_records[rel.inverse_name.parameterize.underscore.to_sym] = related_class(
              relation.primary_record_type,
            ).find(relation.primary_record_id).base_search_data
          end
        end

        related_records
      end

      def extras
        {}
      end

      def related_class(related_record_type)
        "::CoreDataConnector::OpenGeographies::#{related_record_type.split("::").last}".constantize
      end

      def featured
        featured_recs = {}

        relations = ::CoreDataConnector::ProjectModelRelationship.where(primary_model: project_model)

        featureable_relations = relations.map do |prm|
          prm.user_defined_fields.filter { |ud| ud.column_name.downcase.include?('featured') && ud.data_type == 'Boolean' }
        end.flatten.compact

        featureable_relations.each do |fr|
          project_model_relationship = ::CoreDataConnector::ProjectModelRelationship.find(fr.defineable_id)
          rels = ::CoreDataConnector::Relationship.where(project_model_relationship:, primary_record: self)
          featured_rel = rels.find { |rel| rel.user_defined[fr.uuid] }
          next if featured_rel.nil?

          featured_rec = related_class(featured_rel.related_record_type).find(
            featured_rel.related_record.id,
          ).related_search_data
          featured_recs[project_model_relationship.slug.singularize.to_sym] = featured_rec
        end

        return if featured_recs.empty?

        featured_recs
      end
    end
  end
end
