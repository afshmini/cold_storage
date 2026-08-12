# frozen_string_literal: true

require 'active_record'
require 'active_support'
require 'active_support/core_ext/numeric/time'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/time'
require 'active_support/concern'

require 'cold_storage/version'
require 'cold_storage/configuration'
require 'cold_storage/logging'
require 'cold_storage/row_reader'
require 'cold_storage/association_tree'
require 'cold_storage/registry'
require 'cold_storage/policy'
require 'cold_storage/archive_record'
require 'cold_storage/archive_model'
require 'cold_storage/internal_schema'
require 'cold_storage/run'
require 'cold_storage/metadata'
require 'cold_storage/archivable'
require 'cold_storage/model'
require 'cold_storage/schema_mirror'
require 'cold_storage/archiver'
require 'cold_storage/restorer'
require 'cold_storage/report'
require 'cold_storage/jobs'
require 'cold_storage/railtie' if defined?(Rails::Railtie)

# Moves rows that are past their retention window (or soft-deleted) out of the
# primary database and into a mirrored archive database.
#
#   class Payroll < ApplicationRecord
#     archivable after: 18.months, every: 1.month
#   end
#
# See README.md for the full option list.
module ColdStorage
  # Base class for every error raised by the gem.
  Error = Class.new(StandardError)
  # Raised when the archive database is missing or misconfigured.
  ConfigurationError = Class.new(Error)
  # Raised when a model was never declared `archivable`.
  NotArchivableError = Class.new(Error)
  # Raised when the archive database has no table for a model yet.
  SchemaMissingError = Class.new(Error)
  # Raised when an `archivable` declaration is not usable.
  InvalidPolicyError = Class.new(ArgumentError)

  class << self
    # @return [ColdStorage::Configuration]
    def config
      @config ||= Configuration.new
    end

    # @yieldparam config [ColdStorage::Configuration]
    def configure
      yield config
      config
    end

    # Every model that called `archivable`, in declaration-independent order.
    #
    # @param eager_load [Boolean] load the app's classes first so models that
    #   were never referenced in this process are still discovered.
    # @return [Array<Class>]
    def models(eager_load: true)
      Registry.models(eager_load: eager_load)
    end

    # @return [Logger]
    def logger
      config.logger ||= Logger.new($stdout)
    end

    # Archives one model according to its policy.
    #
    # @return [ColdStorage::Archiver::Result]
    def archive(model, **options)
      Archiver.new(model, **options).call
    end

    # Archives every registered model. Models whose `every:` window has not
    # elapsed are skipped unless `force: true`.
    #
    # @return [Array<ColdStorage::Archiver::Result>]
    def archive_all(**options)
      models.map { |model| archive(model, **options) }
    end

    # Moves rows back from the archive database into the primary one.
    #
    #   ColdStorage.restore(Invoice, [1, 2])
    #   ColdStorage.restore(Invoice, [1, 2], with: :all)
    #   ColdStorage.restore(Invoice, Invoice.archived.where(year: 2019),
    #                          with: [:invoice_lines])
    #
    # @param ids [Array, ActiveRecord::Relation]
    # @return [Integer] number of restored rows, children included
    def restore(model, ids, **options)
      Restorer.new(model, **options).call(ids)
    end

    # The archive-database counterpart of a model, for models that are not
    # archivable themselves (a cascade child, say).
    #
    # @return [Class]
    def archived_model(model)
      ArchiveModel.for(model)
    end

    # Creates/updates the archive database tables for the archivable models.
    #
    # @return [Array<ColdStorage::SchemaMirror::Change>]
    def sync_schema!(**options)
      SchemaMirror.new(**options).sync!
    end

    # The changes `sync_schema!` would apply. Empty means the archive database
    # is up to date.
    #
    # @return [Array<ColdStorage::SchemaMirror::Change>]
    def schema_drift(**options)
      SchemaMirror.new(**options).plan
    end

    # @return [String] human readable status of every archivable model
    def report(**options)
      Report.new(**options).to_s
    end

    # @api private
    def reset_config!
      @config = Configuration.new
    end
  end
end
