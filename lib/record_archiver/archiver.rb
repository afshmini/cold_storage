# frozen_string_literal: true

module RecordArchiver
  # Moves rows of one model from the primary database to the archive database.
  #
  # The two databases cannot share a transaction, so every batch is:
  #   1. read from the primary database,
  #   2. upserted into the archive database (idempotent, keyed on the primary
  #      key, so a retry can never duplicate a row),
  #   3. deleted from the primary database.
  #
  # A crash between 2 and 3 leaves the row in both databases; the next run
  # upserts it again and deletes it. Archiving is therefore at-least-once, and
  # never loses a row.
  class Archiver
    include Logging
    include RowReader

    # Outcome of one call.
    Result = Struct.new(:model_name, :archived, :deleted, :skipped, :reason, :dry_run, keyword_init: true) do
      def skipped?
        skipped
      end

      def to_s
        return "#{model_name}: skipped (#{reason})" if skipped?

        "#{model_name}: archived #{archived}, deleted #{deleted}#{' [dry run]' if dry_run}"
      end
    end

    attr_reader :model, :policy, :relation, :result

    # @param model [Class] the ActiveRecord model to archive
    # @param relation [ActiveRecord::Relation, nil] rows to archive, defaults to
    #   what the model's policy selects
    # @param force [Boolean] ignore the `every:` window
    # @param limit [Integer, nil] stop after this many rows
    # @param dry_run [Boolean] report what would move without moving it
    # @param track [Boolean] write a record_archiver_runs row
    # @param cascade [Boolean] also archive the policy's cascade associations
    # @param delete_after_archive [Boolean, nil] override the policy's setting
    def initialize(model, relation: nil, force: false, limit: nil,
                   dry_run: RecordArchiver.config.dry_run, batch_size: nil, track: true,
                   cascade: true, delete_after_archive: nil)
      @model      = model
      @policy     = model.respond_to?(:archiving_policy) ? model.archiving_policy : nil
      @relation   = relation
      @force      = force
      @limit      = limit
      @dry_run    = dry_run
      @batch_size = batch_size
      @track      = track && relation.nil?
      @cascade    = cascade
      @delete_after_archive = delete_after_archive

      return if @policy || @relation

      raise NotArchivableError,
            "#{model} is not archivable. Add `archivable ...` to the model, or pass an explicit relation."
    end

    # @return [Result]
    def call
      return skipped(:destroy_only) if sweep_less?
      return skipped(:not_due) unless due?

      policy&.validate_against_schema!(model)
      ensure_archive_table!

      run = start_run
      archived = 0
      deleted = 0

      each_batch do |rows, ids|
        archived += copy(rows)
        deleted  += cascade_and_delete(ids)
        break if limit_reached?(archived)

        throttle
      end

      run&.succeed!(archived_count: archived, deleted_count: deleted)
      finish(archived, deleted)
    rescue StandardError => e
      run&.fail!(e, archived_count: archived.to_i, deleted_count: deleted.to_i)
      raise
    end

    private

    def due?
      return true if @force || policy.nil?

      policy.due?(Run.last_success_at(model))
    end

    # `archivable on_destroy: true` without an age or scope has nothing for a
    # scheduled run to sweep: it only reacts to deletes.
    def sweep_less?
      @relation.nil? && policy && !policy.sweeps?
    end

    def batch_size
      @batch_size || policy&.batch_size_value || RecordArchiver.config.batch_size
    end

    def delete_after_archive?
      return @delete_after_archive unless @delete_after_archive.nil?

      policy.nil? ? RecordArchiver.config.delete_after_archive : policy.delete_after_archive?
    end

    def delete_method
      policy&.delete_method_value || RecordArchiver.config.delete_method
    end

    def primary_key
      @primary_key ||= model.primary_key
    end

    def scope
      @relation || policy.relation(model)
    end

    def archive_model
      @archive_model ||= ArchiveModel.for(model)
    end

    # Walks the archivable rows in primary key order.
    #
    # Reading raw rows (rather than model instances) keeps the values in their
    # database representation, so model level serializers, default scopes and
    # callbacks cannot change what gets archived.
    def each_batch
      cursor = nil
      moved = 0

      loop do
        batch = scope.reorder(primary_key => :asc).limit(remaining(moved) || batch_size)
        batch = batch.where(model.arel_table[primary_key].gt(cursor)) if cursor

        rows = read(batch)
        break if rows.empty?

        ids = rows.map { |row| row[primary_key] }
        cursor = ids.last
        moved += rows.size

        yield(rows, ids)

        break if rows.size < batch_size
      end
    end

    def remaining(moved)
      return nil unless @limit

      [@limit - moved, 0].max.then { |left| left.zero? ? nil : [left, batch_size].min }
    end

    def read(batch)
      sql = batch.select(model.arel_table[Arel.star]).to_sql
      model.connection_pool.with_connection do |connection|
        select_rows_as_hashes(connection, sql, "#{model} Archive Load")
      end
    end

    def copy(rows)
      return rows.size if @dry_run

      now = Time.current
      payload = rows.map do |row|
        stamped = row.dup
        stamped[archived_at_column.to_s] = now if archived_at_column
        stamped
      end

      archive_model.unscoped.upsert_all(
        payload,
        unique_by: primary_key.to_sym,
        record_timestamps: false,
        returning: false
      )
      rows.size
    end

    def cascade_and_delete(ids)
      archive_children(ids)
      return 0 unless delete_after_archive?
      return ids.size if @dry_run

      target = model.unscoped.where(primary_key => ids)
      model.transaction { target.public_send(delete_method) }
      ids.size
    end

    # Children are archived (and deleted) before their parents, so foreign keys
    # in the primary database stay satisfied at every step.
    def archive_children(parent_ids)
      return if !@cascade || policy.nil? || policy.cascade.empty?

      policy.cascade.each do |association|
        reflection = policy.cascade_reflection!(model, association)
        child_scope = child_relation(reflection, parent_ids)

        self.class.new(
          reflection.klass,
          relation: child_scope,
          force: true,
          dry_run: @dry_run,
          batch_size: batch_size,
          track: false
        ).call
      end
    end

    def child_relation(reflection, parent_ids)
      scope = reflection.klass.unscoped.where(reflection.foreign_key => parent_ids)
      scope = scope.where(reflection.type => model.polymorphic_name) if reflection.type
      scope
    end

    def ensure_archive_table!
      table = model.table_name
      exists = ArchiveRecord.with_archive_connection { |connection| connection.table_exists?(table) }
      return if exists

      raise SchemaMissingError,
            "The archive database has no #{table} table yet. " \
            'Run `rails record_archiver:schema:sync` (or RecordArchiver.sync_schema!) first.'
    end

    def archived_at_column
      column = RecordArchiver.config.archived_at_column
      return nil if column.nil?
      return nil if model.column_names.include?(column.to_s)

      column
    end

    def start_run
      return nil if @dry_run || !@track

      Run.start!(model)
    end

    def limit_reached?(archived)
      @limit && archived >= @limit
    end

    def throttle
      sleep(RecordArchiver.config.throttle) if RecordArchiver.config.throttle.to_f.positive?
    end

    def skipped(reason)
      result = Result.new(model_name: model.to_s, archived: 0, deleted: 0, skipped: true,
                          reason: reason, dry_run: @dry_run)
      log(result.to_s)
      result
    end

    def finish(archived, deleted)
      result = Result.new(model_name: model.to_s, archived: archived, deleted: deleted,
                          skipped: false, reason: nil, dry_run: @dry_run)
      log(result.to_s)
      result
    end
  end
end
