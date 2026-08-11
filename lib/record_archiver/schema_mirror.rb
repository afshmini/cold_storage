# frozen_string_literal: true

require 'digest'

module RecordArchiver
  # Copies the table definitions of the archivable models (and of the tables
  # they cascade into) from the primary database to the archive database, and
  # keeps them in sync when migrations change them.
  #
  # Deliberate differences from the source schema:
  #   * no foreign keys       - an archive holds partial object graphs
  #   * no NOT NULL, no default values (configurable) - a schema that got
  #     stricter later must never reject rows archived before that
  #   * columns are added, never dropped (configurable) - archived rows keep
  #     the columns they were archived with
  #   * one extra column, `archived_at`
  class SchemaMirror
    include Logging

    # A single difference between the two schemas.
    Change = Struct.new(:type, :table, :name, :detail, keyword_init: true) do
      def to_s
        [type, table, name, detail].compact.join(' ')
      end
    end

    attr_reader :changes

    # @param models [Array<Class>, nil] defaults to every archivable model
    # @param dry_run [Boolean] plan only, never touch the archive database
    def initialize(models: nil, dry_run: RecordArchiver.config.dry_run, logger_prefix: nil)
      @models  = models
      @dry_run = dry_run
      @logger_prefix = logger_prefix
      @changes = []
    end

    # Applies the changes.
    # @return [Array<Change>] what was applied
    def sync!
      run(apply: !@dry_run)
    end

    # @return [Array<Change>] what sync! would apply; empty means "in sync"
    def plan
      run(apply: false)
    end
    alias check plan

    # Tables the archive database is expected to hold, derived from the models.
    # @return [Hash{String => Class}] table name => source model
    def tables
      @tables ||= begin
        map = {}
        source_models.each { |model| collect_tables(model, map) }
        map
      end
    end

    def source_models
      @source_models ||= (@models || RecordArchiver.models).map { |m| m.is_a?(String) ? m.constantize : m }
    end

    private

    def run(apply:)
      @changes = []
      ArchiveRecord.connect!
      InternalSchema.ensure! if apply

      ArchiveRecord.with_archive_connection do |target|
        tables.each { |table, model| mirror_table(model, table, target, apply) }
      end

      record_schema_version if apply
      log_summary(apply)
      changes
    end

    # ------------------------------------------------------------------ tables

    def collect_tables(model, map, cascade = nil, seen = [])
      return if seen.include?(model.table_name)

      seen += [model.table_name]
      map[model.table_name] ||= model

      tree = cascade || policy_cascade(model)
      tree.each do |association, nested|
        reflection = Policy.cascade_reflection!(model, association)
        child_tree = nested.nil? ? policy_cascade(reflection.klass) : AssociationTree.normalize(nested)
        collect_tables(reflection.klass, map, child_tree, seen)
      end
    end

    def policy_cascade(model)
      return {} unless model.respond_to?(:archiving_policy) && model.archiving_policy

      model.archiving_policy.cascade
    end

    def mirror_table(model, table, target, apply)
      source_columns = columns_for(model)
      mirror_enum_types(model, source_columns, target, apply)

      if target.table_exists?(table)
        sync_columns(table, source_columns, target, apply)
      else
        create_table(model, table, source_columns, target, apply)
      end

      ensure_archived_at(table, source_columns, target, apply)
      sync_indexes(model, table, target, apply) if RecordArchiver.config.mirror_indexes
    end

    def create_table(model, table, source_columns, target, apply)
      record(:create_table, table, nil, "#{source_columns.size} columns")
      return unless apply

      target.create_table(table, id: false) do |t|
        source_columns.each do |column|
          t.column(column.name, sql_type_for(column), **column_options(column))
        end
      end

      primary_key = model.primary_key
      return if primary_key.blank?

      quoted = Array(primary_key).map { |key| target.quote_column_name(key) }.join(', ')
      target.execute("ALTER TABLE #{target.quote_table_name(table)} ADD PRIMARY KEY (#{quoted})")
    end

    def sync_columns(table, source_columns, target, apply)
      archive_columns = target.columns(table).index_by(&:name)

      source_columns.each do |column|
        existing = archive_columns[column.name]

        if existing.nil?
          record(:add_column, table, column.name, sql_type_for(column))
          target.add_column(table, column.name, sql_type_for(column), **column_options(column)) if apply
        elsif normalize_type(sql_type_for(existing)) != normalize_type(sql_type_for(column))
          handle_type_mismatch(table, column, existing, target, apply)
        end
      end

      removed = archive_columns.keys - source_columns.map(&:name) - [archived_at_column.to_s]
      removed.each { |name| handle_removed_column(table, name, target, apply) }
    end

    def handle_type_mismatch(table, column, existing, target, apply)
      from = sql_type_for(existing)
      to = sql_type_for(column)
      message = "#{table}.#{column.name} is #{from} in the archive but #{to} in the primary database"

      case RecordArchiver.config.on_type_mismatch
      when :raise
        raise Error, message
      when :change
        record(:change_column, table, column.name, "#{from} -> #{to}")
        target.change_column(table, column.name, to, **column_options(column)) if apply
      when :warn
        record(:type_mismatch, table, column.name, "#{from} != #{to}")
        warn_log(message)
      end
    end

    def handle_removed_column(table, name, target, apply)
      if RecordArchiver.config.drop_removed_columns
        record(:remove_column, table, name, nil)
        target.remove_column(table, name) if apply
      else
        record(:extra_column, table, name, 'kept (drop_removed_columns is false)')
      end
    end

    def ensure_archived_at(table, source_columns, target, apply)
      column = archived_at_column
      return if column.nil?

      if source_columns.any? { |c| c.name == column.to_s }
        warn_log("#{table} already has a #{column} column; RecordArchiver will not stamp it")
        return
      end
      return if target.table_exists?(table) && target.column_exists?(table, column)

      record(:add_column, table, column.to_s, 'datetime (archived_at)')
      return unless apply

      target.add_column(table, column, :datetime)
      target.add_index(table, column, name: index_name(table, [column.to_s], 'archived_at'))
    end

    # ----------------------------------------------------------------- indexes

    def sync_indexes(model, table, target, apply)
      return if !apply && !target.table_exists?(table)

      source_indexes = with_source_connection(model) { |source| source.indexes(table) }
      existing = target.indexes(table).map(&:name)

      source_indexes.each do |index|
        next if existing.include?(index.name)

        record(:add_index, table, index.name, Array(index.columns).join(', '))
        next unless apply

        add_index(target, table, index)
      end
    end

    def add_index(target, table, index)
      options = {
        name: index.name,
        unique: index.unique,
        where: index.where,
        using: index.using,
        order: index.orders.presence,
        opclass: index.opclasses.presence
      }.compact

      target.add_index(table, index.columns, **options)
    rescue StandardError => e
      # An index is never worth failing a sync for: the data still fits.
      warn_log("could not mirror index #{index.name} on #{table}: #{e.class}: #{e.message}")
    end

    # ------------------------------------------------------------- enum types

    def mirror_enum_types(model, source_columns, target, apply)
      return unless target.respond_to?(:enum_types)

      source_enums = enum_types_for(model)
      return if source_enums.empty?

      existing = target.enum_types.to_h.keys
      used = source_columns.map { |column| base_type(column.sql_type) }.uniq

      used.each do |type|
        values = source_enums[type]
        next if values.nil? || existing.include?(type)

        record(:create_enum, nil, type, Array(values).join(', '))
        target.create_enum(type, Array(values)) if apply
      end
    end

    def enum_types_for(model)
      @enum_types ||= {}
      @enum_types[model.connection_pool.db_config.name] ||=
        with_source_connection(model) do |source|
          source.respond_to?(:enum_types) ? source.enum_types.to_h : {}
        end
    end

    def base_type(sql_type)
      sql_type.to_s.sub(/\[\]\z/, '').sub(/\(.*\)\z/, '').strip
    end

    # ------------------------------------------------------------------ shared

    def columns_for(model)
      with_source_connection(model) { |source| source.columns(model.table_name) }
    end

    def with_source_connection(model, &block)
      model.connection_pool.with_connection(&block)
    end

    def column_options(column)
      options = {}
      options[:null] = column.null if RecordArchiver.config.mirror_null_constraints
      if RecordArchiver.config.mirror_defaults && column.default_function.nil?
        options[:default] = column.default
      end
      options
    end

    # PostgreSQL reports an array column as its element type plus a separate
    # array flag, so the "[]" has to be put back before the type can be used in
    # DDL again.
    def sql_type_for(column)
      type = column.sql_type
      type = "#{type}[]" if column.respond_to?(:array?) && column.array?
      type
    end

    def normalize_type(sql_type)
      sql_type.to_s.downcase.gsub(/\s+/, ' ').strip
    end

    def archived_at_column
      RecordArchiver.config.archived_at_column
    end

    def index_name(table, columns, suffix)
      name = "index_#{table}_on_#{columns.join('_and_')}"
      name = "idx_ra_#{Digest::MD5.hexdigest(name)[0, 20]}_#{suffix}" if name.length > 63
      name
    end

    def record(type, table, name, detail)
      change = Change.new(type: type, table: table, name: name, detail: detail)
      changes << change
      log(change.to_s)
      change
    end

    def record_schema_version
      version = source_schema_version
      Metadata.schema_version = version if version
    end

    def source_schema_version
      model = source_models.first || ActiveRecord::Base
      model.connection_pool.migration_context.current_version
    rescue StandardError
      nil
    end

    def log_summary(apply)
      verb = apply ? 'applied' : 'pending'
      if changes.empty?
        log("archive schema is up to date (#{tables.size} tables)")
      else
        log("#{changes.size} schema change(s) #{verb} across #{tables.size} table(s)")
      end
    end
  end
end
