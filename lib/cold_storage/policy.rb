# frozen_string_literal: true

module ColdStorage
  # The `archivable` options of a single model, and the relation they describe.
  #
  #   archivable after: 18.months                  # older than 18 months
  #   archivable after: 30.days, on: :closed_at    # ... measured on another column
  #   archivable deleted: true                     # soft-deleted rows only
  #   archivable deleted: true, after: 90.days     # soft-deleted 90+ days ago
  #   archivable after: 1.year, every: 1.month     # ... and only run monthly
  #   archivable after: 2.years, cascade: [:items] # take the children along
  #   archivable after: 2.years, cascade: { items: [:taxes] } # ... and theirs
  #   archivable on_destroy: true                  # catch hard deletes
  class Policy
    OPTIONS = %i[
      after older_than on deleted deleted_column every scope
      batch_size delete_after_archive delete_method cascade
      on_destroy hard_delete
    ].freeze

    attr_reader :model_name, :after, :on, :every, :scope, :batch_size,
                :delete_method, :cascade, :deleted_column

    def initialize(model, **options)
      unknown = options.keys - OPTIONS
      unless unknown.empty?
        raise InvalidPolicyError,
              "unknown archivable option(s) #{unknown.map(&:inspect).join(', ')} for #{model}. " \
              "Known options: #{OPTIONS.map(&:inspect).join(', ')}"
      end

      @model_name           = model.name
      @after                = normalize_duration(options[:after] || options[:older_than])
      @deleted              = options.fetch(:deleted, false)
      @deleted_column       = (options[:deleted_column] || ColdStorage.config.deleted_column).to_sym
      @on                   = (options[:on] || default_column).to_sym
      @every                = normalize_duration(options[:every])
      @scope                = options[:scope]
      @batch_size           = options[:batch_size]
      @delete_after_archive = options[:delete_after_archive]
      @delete_method        = options[:delete_method]
      @cascade              = AssociationTree.normalize(options[:cascade])
      @on_destroy           = options.fetch(:on_destroy) { options.fetch(:hard_delete, false) }

      validate!
    end

    def deleted?
      @deleted
    end

    # Copy the row to the archive when it is really destroyed.
    def on_destroy?
      @on_destroy
    end

    # Does this policy describe rows a scheduled run should sweep up?
    # `on_destroy: true` on its own does not: it only reacts to deletes.
    def sweeps?
      !after.nil? || deleted? || !scope.nil?
    end

    def model
      @model_name.constantize
    end

    def batch_size_value
      batch_size || ColdStorage.config.batch_size
    end

    def delete_after_archive?
      @delete_after_archive.nil? ? ColdStorage.config.delete_after_archive : @delete_after_archive
    end

    def delete_method_value
      delete_method || ColdStorage.config.delete_method
    end

    # The rows that are archivable right now.
    #
    # Always starts from `unscoped`: a soft-delete default scope would
    # otherwise hide exactly the rows we are asked to archive.
    #
    # @return [ActiveRecord::Relation]
    def relation(klass = model)
      return klass.none unless sweeps?

      relation = klass.unscoped
      relation = relation.where.not(deleted_column => nil) if deleted?
      relation = relation.where(klass.arel_table[on].lt(cutoff)) if after
      apply_scope(relation)
    end

    # @return [Time, nil] rows on the `on:` column older than this are archivable
    def cutoff(now = Time.current)
      return nil unless after

      now - after
    end

    # Has enough time passed since the last successful run?
    def due?(last_run_at)
      return true if every.nil? || last_run_at.nil?

      last_run_at <= Time.current - every
    end

    # Checks the options against the real table. Raises with an actionable
    # message instead of failing later with a SQL error.
    def validate_against_schema!(klass = model)
      columns = klass.column_names
      check_column!(klass, on, columns)
      check_column!(klass, deleted_column, columns) if deleted?

      if klass.primary_key.nil? || klass.primary_key.is_a?(Array)
        raise InvalidPolicyError,
              "#{klass} must have a single-column primary key to be archivable (got #{klass.primary_key.inspect})"
      end

      validate_cascade!(klass, cascade)
      true
    end

    def cascade_reflection!(klass, name)
      self.class.cascade_reflection!(klass, name)
    end

    # @return [ActiveRecord::Reflection::AssociationReflection]
    def self.cascade_reflection!(klass, name)
      reflection = klass.reflect_on_association(name)
      raise InvalidPolicyError, "#{klass} has no association #{name.inspect} to cascade to" if reflection.nil?

      if reflection.through_reflection?
        raise InvalidPolicyError, "cascade does not support :through associations (#{klass}##{name})"
      end

      unless reflection.collection? || reflection.has_one?
        raise InvalidPolicyError,
              "cascade only supports has_many / has_one associations (#{klass}##{name} is a #{reflection.macro})"
      end

      reflection
    end

    # @return [String] one-line summary used by the status report
    def to_s
      parts = []
      parts << 'deleted' if deleted?
      parts << "#{on} < #{humanize_duration(after)} ago" if after
      parts << "scope: #{scope.is_a?(Symbol) ? scope : 'custom'}" if scope
      parts << 'on destroy' if on_destroy?
      parts << "every #{humanize_duration(every)}" if every && sweeps?
      parts << "cascade: #{cascade.keys.join(', ')}" if cascade.any?
      parts << 'keeps source rows' unless delete_after_archive?
      parts.join(', ')
    end

    private

    def default_column
      @deleted ? @deleted_column : ColdStorage.config.timestamp_column
    end

    def apply_scope(relation)
      case scope
      when nil    then relation
      when Symbol then relation.public_send(scope)
      when Proc   then relation.instance_exec(&scope)
      else relation.merge(scope)
      end
    end

    def validate!
      return if sweeps? || on_destroy?

      raise InvalidPolicyError,
            "#{model_name}: archivable needs at least one of after:, deleted:, scope: or on_destroy:. " \
            'Without a criterion every row of the table would be archived.'
    end

    # Walks the whole cascade tree, so a typo deep in it is reported before
    # anything moves.
    def validate_cascade!(klass, tree)
      tree.each do |name, nested|
        reflection = self.class.cascade_reflection!(klass, name)
        validate_cascade!(reflection.klass, AssociationTree.normalize(nested))
      end
    end

    def check_column!(klass, column, columns)
      return if columns.include?(column.to_s)

      raise InvalidPolicyError,
            "#{klass} has no column #{column.inspect} (archivable on:/deleted_column:). " \
            "Available: #{columns.sort.join(', ')}"
    end

    def normalize_duration(value)
      case value
      when nil then nil
      when ActiveSupport::Duration then value
      when Numeric then value.seconds
      else
        raise InvalidPolicyError, "expected a duration like 6.months, got #{value.inspect}"
      end
    end

    def humanize_duration(duration)
      duration.inspect
    end
  end
end
