# frozen_string_literal: true

module ColdStorage
  # Extended onto ActiveRecord::Base, so every model can declare itself
  # archivable.
  module Model
    # Declares which rows of this model move to the archive database.
    #
    #   class Payroll < ApplicationRecord
    #     archivable after: 18.months, every: 1.month
    #   end
    #
    # Options:
    #   after:                Duration. Rows older than this are archivable.
    #                         (alias: older_than:)
    #   on:                   Column the age is measured on.
    #                         Default: :created_at, or the deleted column when
    #                         deleted: true.
    #   deleted:              true to archive soft-deleted rows only.
    #   deleted_column:       Column holding the soft-delete timestamp.
    #                         Default: ColdStorage.config.deleted_column.
    #   on_destroy:           true to copy a row to the archive whenever it is
    #                         really deleted (destroy/destroy_all), so hard
    #                         deletes are kept too. (alias: hard_delete:)
    #   every:                Duration. Minimum time between two runs.
    #   scope:                Symbol, proc or relation narrowing the selection.
    #   cascade:              has_many/has_one association names to archive
    #                         together with their parent.
    #   batch_size:           Rows moved per round trip.
    #   delete_after_archive: false to copy without deleting the source rows.
    #   delete_method:        :delete_all (default) or :destroy_all.
    #
    # @return [ColdStorage::Policy]
    def archivable(**options)
      include ColdStorage::Archivable unless include?(ColdStorage::Archivable)

      self.archiving_policy = Policy.new(self, **options)
      install_archive_on_destroy! if archiving_policy.on_destroy?
      Registry.register(self)
      archiving_policy
    end

    # Every model answers this, so callers never have to rescue NoMethodError.
    def archivable?
      false
    end
  end
end
