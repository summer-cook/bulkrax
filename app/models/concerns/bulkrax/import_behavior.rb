# frozen_string_literal: true

module Bulkrax
  # Import Behavior for Entry classes
  module ImportBehavior
    extend ActiveSupport::Concern

    def build_for_importer
      begin
        build_metadata
        unless self.importerexporter.validate_only
          raise CollectionsCreatedError unless collections_created?
          @item = factory.run!
        end
        parent_jobs if self.parsed_metadata[related_parents_parsed_mapping].present?
        child_jobs if self.parsed_metadata[related_children_parsed_mapping].present?
      rescue RSolr::Error::Http, CollectionsCreatedError => e
        raise e
      rescue StandardError => e
        status_info(e)
      else
        status_info
      end
      return @item
    end

    def parent_jobs
      self.parsed_metadata[related_parents_parsed_mapping].each do |parent_identifier|
        CreateRelationshipsJob.perform_later(entry_identifier: self.identifier, parent_identifier: parent_identifier, importer_run: self.last_run)
      end
    end

    def child_jobs
      self.parsed_metadata[related_children_parsed_mapping].each do |child_identifier|
        CreateRelationshipsJob.perform_later(entry_identifier: self.identifier, child_identifier: child_identifier, importer_run: self.last_run)
      end
    end

    def find_collection_ids
      self.collection_ids
    end

    # override this in a sub-class of Entry to ensure any collections have been created before building the work
    def collections_created?
      true
    end

    def build_metadata
      raise StandardError, 'Not Implemented'
    end

    def rights_statement
      parser.parser_fields['rights_statement']
    end

    # try and deal with a couple possible states for this input field
    def override_rights_statement
      %w[true 1].include?(parser.parser_fields['override_rights_statement'].to_s)
    end

    def add_rights_statement
      self.parsed_metadata['rights_statement'] = [parser.parser_fields['rights_statement']] if override_rights_statement || self.parsed_metadata['rights_statement'].blank?
    end

    def add_visibility
      self.parsed_metadata['visibility'] = importerexporter.visibility if self.parsed_metadata['visibility'].blank?
    end

    def add_admin_set_id
      self.parsed_metadata['admin_set_id'] = importerexporter.admin_set_id if self.parsed_metadata['admin_set_id'].blank?
    end

    def add_collections
      return if find_collection_ids.blank?

      ActiveSupport::Deprecation.warn(
        'Creating Collections using the collection_field_mapping will no longer be supported as of Bulkrax version 3.0.' \
        ' Please configure Bulkrax to use related_parents_field_mapping and related_children_field_mapping instead.'
      )
      self.parsed_metadata['member_of_collections_attributes'] = {}
      find_collection_ids.each_with_index do |c, i|
        self.parsed_metadata['member_of_collections_attributes'][i.to_s] = { id: c }
      end
    end

    def factory
      ActiveSupport::Deprecation.warn(
        'Creating Collections using the collection_field_mapping will no longer be supported as of Bulkrax version 3.0.' \
        ' Please configure Bulkrax to use related_parents_field_mapping and related_children_field_mapping instead.'
      )
      @factory ||= Bulkrax::ObjectFactory.new(attributes: self.parsed_metadata,
                                              source_identifier_value: identifier,
                                              work_identifier: parser.work_identifier,
                                              collection_field_mapping: parser.collection_field_mapping,
                                              replace_files: replace_files,
                                              user: user,
                                              klass: factory_class,
                                              update_files: update_files)
    end

    def factory_class
      fc = if self.parsed_metadata&.[]('model').present?
             self.parsed_metadata&.[]('model').is_a?(Array) ? self.parsed_metadata&.[]('model')&.first : self.parsed_metadata&.[]('model')
           elsif self.mapping&.[]('work_type').present?
             self.parsed_metadata&.[]('work_type').is_a?(Array) ? self.parsed_metadata&.[]('work_type')&.first : self.parsed_metadata&.[]('work_type')
           else
             Bulkrax.default_work_type
           end

      # return the name of the collection or work
      fc.tr!(' ', '_')
      fc.downcase! if fc.match?(/[-_]/)
      fc.camelcase.constantize
    rescue NameError
      nil
    rescue
      Bulkrax.default_work_type.constantize
    end
  end
end
