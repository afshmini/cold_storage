# frozen_string_literal: true

module RecordArchiver
  # Mixed into a model the first time it declares `archivable`.
  module Archivable
    extend ActiveSupport::Concern

    included do
      class_attribute :archiving_policy, instance_accessor: false, default: nil
      class_attribute :archiving_destroy_hook, instance_accessor: false, default: false
    end

    class_methods do
      def archivable?
        archiving_policy.present?
      end

      # Copies a row to the archive just before it is really deleted.
      # Installed by `archivable on_destroy: true`.
      def install_archive_on_destroy!
        return if archiving_destroy_hook

        self.archiving_destroy_hook = true
        # prepend: so the row is captured before dependent: callbacks start
        # taking its children apart.
        before_destroy(:archive_before_destroy, prepend: true)
      end

      # Rows that are eligible for archiving right now.
      # @return [ActiveRecord::Relation]
      def archivable_records
        archiving_policy!.relation(self)
      end

      # How many rows are waiting to be archived.
      def archivable_count
        archivable_records.count
      end

      # Handle on the archived rows, living in the archive database. An
      # ordinary relation: scopes, where, pluck, find_each all work, and the
      # model's associations are mirrored, so archived children come along.
      #
      #   Payroll.archived.where(company_id: 1).count
      #   Invoice.archived.find(42).invoice_lines
      #
      # @return [ActiveRecord::Relation]
      def archived
        archive_model.all
      end

      # How many rows of this model sit in the archive.
      def archived_count
        archived.count
      end

      # @return [ActiveRecord::Base] the archived row
      # @raise [ActiveRecord::RecordNotFound]
      def find_archived(*ids)
        archive_model.find(*ids)
      end

      # Looks in the primary database first, then in the archive.
      #
      # @return [ActiveRecord::Base] a live record, or an archived one
      # @raise [ActiveRecord::RecordNotFound] when it is in neither
      def find_with_archived(id)
        unscoped.find_by(primary_key => id) || find_archived(id)
      end

      # Moves archived rows back into this table.
      #
      #   Payroll.restore_archived([1, 2, 3])
      #   Invoice.restore_archived(Invoice.archived.where(year: 2019), with: :all)
      #
      # @return [Integer] number of restored rows, children included
      def restore_archived(ids, **options)
        RecordArchiver.restore(self, ids, **options)
      end

      # The ActiveRecord class mapped onto this table in the archive database.
      # @return [Class]
      def archive_model
        ArchiveModel.for(self)
      end

      # Archives this model now, ignoring the `every:` window by default.
      # @return [RecordArchiver::Archiver::Result]
      def archive_now!(**options)
        Archiver.new(self, **{ force: true }.merge(options)).call
      end

      # @return [RecordArchiver::Policy]
      def archiving_policy!
        archiving_policy || raise(NotArchivableError, "#{name} is not archivable")
      end
    end

    # Archives this single record (and its cascaded children).
    # @return [RecordArchiver::Archiver::Result]
    def archive!
      relation = self.class.unscoped.where(self.class.primary_key => id)
      Archiver.new(self.class, relation: relation, force: true).call
    end

    # Is there a row with this id in the archive database?
    def archived?
      self.class.archive_model.where(self.class.primary_key => id).exists?
    end

    private

    # Keeps a copy of a hard-deleted row. The row is still readable here, so it
    # is read (and archived) exactly like the scheduled run would.
    #
    # The policy's cascade comes along, because `dependent: :destroy` children
    # are about to go too. Nothing is deleted here: the destroy that triggered
    # this is what removes the rows, so `dependent:` keeps deciding what
    # happens to the children.
    #
    # Raises by default: losing the row is worse than failing the delete. Set
    # `config.on_destroy_error = :log` to let deletes through instead.
    def archive_before_destroy
      return unless RecordArchiver.config.enabled
      return unless self.class.archiving_policy&.on_destroy?
      return if new_record? || id.nil?

      Archiver.new(
        self.class,
        relation: self.class.unscoped.where(self.class.primary_key => id),
        force: true,
        track: false,
        cascade: true,
        delete_after_archive: false
      ).call
    rescue StandardError => e
      raise if RecordArchiver.config.on_destroy_error == :raise

      RecordArchiver.logger.error do
        "#{Logging::PREFIX} could not archive #{self.class}##{id} before destroy: #{e.class}: #{e.message}"
      end
    end
  end
end
