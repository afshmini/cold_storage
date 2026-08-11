# frozen_string_literal: true

module RecordArchiver
  # Moves rows back from the archive database into the primary one, optionally
  # taking their archived children along.
  #
  #   RecordArchiver.restore(Invoice, [1, 2])
  #   RecordArchiver.restore(Invoice, [1, 2], with: :all)
  #   RecordArchiver.restore(Invoice, [1, 2], with: [:invoice_lines])
  #   RecordArchiver.restore(Invoice, [1, 2], with: { invoice_lines: [:taxes] })
  #
  # Parents are written before their children, so foreign keys in the primary
  # database hold at every step.
  class Restorer
    include Logging
    include RowReader

    attr_reader :model

    # @param with [Symbol, Array, Hash, nil] associations to restore too;
    #   `:all` walks every has_many/has_one that has an archive table
    # @param delete_from_archive [Boolean] remove the rows from the archive
    #   once they are back in the primary database
    def initialize(model, with: nil, delete_from_archive: true, batch_size: nil,
                   dry_run: RecordArchiver.config.dry_run, visited: [])
      @model               = model
      @with                = with
      @delete_from_archive = delete_from_archive
      @batch_size          = batch_size || RecordArchiver.config.batch_size
      @dry_run             = dry_run
      @visited             = visited
    end

    # @param ids [Array, ActiveRecord::Relation] ids to restore, or a relation
    #   on the archive model (Invoice.archived.where(...))
    # @return [Integer] number of restored rows, children included
    def call(ids)
      validate_associations!

      relation = normalize(ids)
      restored = 0
      own = 0

      relation.in_batches(of: @batch_size) do |batch|
        rows = read(batch)
        next if rows.empty?

        own += write(rows)
        restored_ids = rows.map { |row| row[primary_key] }
        restored += restore_associations(restored_ids)
        delete(restored_ids)
      end

      log("#{model}: restored #{own} row(s) from the archive#{' [dry run]' if @dry_run}")
      own + restored
    end

    # The associations `with:` resolves to, as association name => nested with.
    # @return [Hash{Symbol => Object}]
    def associations
      @associations ||= expand(@with)
    end

    private

    def primary_key
      @primary_key ||= model.primary_key
    end

    def archive_model
      @archive_model ||= ArchiveModel.for(model)
    end

    def normalize(ids)
      return ids if ids.is_a?(ActiveRecord::Relation)

      archive_model.where(primary_key => Array(ids))
    end

    def read(batch)
      sql = batch.select(archive_model.arel_table[Arel.star]).to_sql
      rows = ArchiveRecord.with_archive_connection do |connection|
        select_rows_as_hashes(connection, sql, "#{model} Restore Load")
      end

      stamp = RecordArchiver.config.archived_at_column
      rows.each { |row| row.delete(stamp.to_s) } if stamp
      rows
    end

    def write(rows)
      return rows.size if @dry_run

      # unscoped: a default scope would otherwise force its own values (a
      # soft-delete scope would resurrect rows as "not deleted").
      model.unscoped.upsert_all(rows, unique_by: primary_key.to_sym, record_timestamps: false, returning: false)
      rows.size
    end

    def delete(ids)
      return unless @delete_from_archive && !@dry_run

      archive_model.where(primary_key => ids).delete_all
    end

    # ------------------------------------------------------------ associations

    # Checked before anything is written: a typo in `with:` must not leave a
    # half restored graph behind.
    def validate_associations!
      associations.each_key do |name|
        reflection = reflection_for(name)
        assert_archive_table!(reflection.klass, name)
      end
    end

    def restore_associations(parent_ids)
      return 0 if associations.empty?

      associations.sum do |name, nested|
        reflection = reflection_for(name)
        child = reflection.klass

        self.class.new(
          child,
          with: nested,
          delete_from_archive: @delete_from_archive,
          batch_size: @batch_size,
          dry_run: @dry_run,
          visited: @visited + [model.table_name]
        ).call(child_relation(reflection, parent_ids))
      end
    end

    def child_relation(reflection, parent_ids)
      scope = ArchiveModel.for(reflection.klass).where(reflection.foreign_key => parent_ids)
      scope = scope.where(reflection.type => model.polymorphic_name) if reflection.type
      scope
    end

    def reflection_for(name)
      reflection = model.reflect_on_association(name)
      raise ArgumentError, "#{model} has no association #{name.inspect} to restore" if reflection.nil?

      if reflection.macro == :belongs_to
        raise ArgumentError,
              "#{model}##{name} is a belongs_to; restore the owner first, then its children"
      end

      reflection
    end

    def assert_archive_table!(child, name)
      exists = ArchiveRecord.with_archive_connection { |c| c.table_exists?(child.table_name) }
      return if exists

      raise SchemaMissingError,
            "The archive database has no #{child.table_name} table, so #{model}##{name} cannot be restored."
    end

    # `with:` accepts a symbol, an array, a nested hash, or :all.
    def expand(value)
      return every_child_association if value == true || value == :all

      AssociationTree.normalize(value)
    rescue ArgumentError
      raise ArgumentError, "with: expects a symbol, array, hash or :all, got #{value.inspect}"
    end

    # Every child association that actually has something to restore. Cycles
    # are cut with the tables already visited on the way down.
    def every_child_association
      model.reflect_on_all_associations.each_with_object({}) do |reflection, result|
        next unless %i[has_many has_one].include?(reflection.macro)
        next if reflection.options[:through] || reflection.options[:polymorphic]

        target = child_table(reflection)
        next if target.nil? || @visited.include?(target)

        result[reflection.name] = :all
      end
    end

    def child_table(reflection)
      table = reflection.klass.table_name
      return nil if table.blank? || table == model.table_name

      exists = ArchiveRecord.with_archive_connection { |c| c.table_exists?(table) }
      exists ? table : nil
    rescue StandardError
      nil
    end
  end
end
