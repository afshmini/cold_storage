# frozen_string_literal: true

module RecordArchiver
  # Global defaults. Every model can override most of these through its own
  # `archivable` options.
  class Configuration
    TYPE_MISMATCH_STRATEGIES = %i[warn raise change ignore].freeze

    # Name of the database.yml entry holding the archive database.
    attr_accessor :archive_database
    # Rows copied (and deleted) per round trip.
    attr_accessor :batch_size
    # Default column used to decide how old a record is.
    attr_accessor :timestamp_column
    # Default column used by `deleted: true`.
    attr_accessor :deleted_column
    # Extra column added to every archive table, holding the archiving time.
    # Set to nil to disable.
    attr_accessor :archived_at_column
    # Delete rows from the primary database once they are safely copied.
    attr_accessor :delete_after_archive
    # :delete_all (fast, no callbacks) or :destroy_all (slow, runs callbacks).
    attr_accessor :delete_method
    # Copy indexes to the archive tables.
    attr_accessor :mirror_indexes
    # Copy NOT NULL constraints. Off by default: an archive table should never
    # reject historical rows because the primary schema grew stricter later.
    attr_accessor :mirror_null_constraints
    # Copy column defaults. Off by default, rows are always inserted complete.
    attr_accessor :mirror_defaults
    # Drop archive columns that no longer exist in the primary database. Off by
    # default so that already archived data keeps its columns.
    attr_accessor :drop_removed_columns
    # What to do when a column type differs: :warn, :raise, :change or :ignore.
    attr_reader :on_type_mismatch
    # What to do when `on_destroy:` cannot reach the archive database:
    # :raise (block the delete, keep the data) or :log (let the delete through).
    attr_reader :on_destroy_error
    # Run the schema mirror automatically after db:migrate / db:schema:load.
    attr_accessor :sync_schema_after_migrate
    # Seconds to sleep between batches, to keep long runs off the hot path.
    attr_accessor :throttle
    # ActiveJob queue used by the bundled jobs.
    attr_accessor :job_queue
    # Parent class of the bundled jobs, as a string.
    attr_accessor :job_parent_class
    # Log every statement/plan the gem produces without touching any data.
    attr_accessor :dry_run
    attr_accessor :logger

    def initialize
      @archive_database          = :archive
      @batch_size                = 1_000
      @timestamp_column          = :created_at
      @deleted_column            = :deleted_at
      @archived_at_column        = :archived_at
      @delete_after_archive      = true
      @delete_method             = :delete_all
      @mirror_indexes            = true
      @mirror_null_constraints   = false
      @mirror_defaults           = false
      @drop_removed_columns      = false
      @on_type_mismatch          = :warn
      @on_destroy_error          = :raise
      @sync_schema_after_migrate = true
      @throttle                  = 0
      @job_queue                 = :default
      @job_parent_class          = 'ActiveJob::Base'
      @dry_run                   = false
      @logger                    = nil
    end

    def on_type_mismatch=(strategy)
      strategy = strategy.to_sym
      unless TYPE_MISMATCH_STRATEGIES.include?(strategy)
        raise ConfigurationError,
              "on_type_mismatch must be one of #{TYPE_MISMATCH_STRATEGIES.join(', ')}, got #{strategy.inspect}"
      end

      @on_type_mismatch = strategy
    end

    def on_destroy_error=(strategy)
      strategy = strategy.to_sym
      raise ConfigurationError, 'on_destroy_error must be :raise or :log' unless %i[raise log].include?(strategy)

      @on_destroy_error = strategy
    end

    def delete_method=(method)
      method = method.to_sym
      unless %i[delete_all destroy_all].include?(method)
        raise ConfigurationError, "delete_method must be :delete_all or :destroy_all, got #{method.inspect}"
      end

      @delete_method = method
    end
  end
end
