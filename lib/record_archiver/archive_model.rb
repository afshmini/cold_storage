# frozen_string_literal: true

require 'monitor'

module RecordArchiver
  # Namespace holding the generated archive classes, so they have real names in
  # logs and backtraces (RecordArchiver::Archived::Invoices).
  #
  # Classes appear here on demand: an association declared on one archive model
  # names its counterpart, and the constant is built the first time it is
  # touched.
  module Archived
    def self.const_missing(name)
      source = ArchiveModel.registered_source(name)
      return super if source.nil?

      ArchiveModel.for(source)
    end
  end

  # Builds, and caches, the ActiveRecord class that reads and writes a mirrored
  # table in the archive database.
  module ArchiveModel
    MIRRORED_MACROS = %i[has_many has_one belongs_to].freeze
    MONITOR = Monitor.new
    private_constant :MONITOR

    class << self
      # @param source [Class] an ActiveRecord model in the primary database
      # @return [Class] its counterpart in the archive database
      def for(source)
        ArchiveRecord.connect!
        cache[source.table_name] || MONITOR.synchronize { cache[source.table_name] ||= build(source) }
      end

      # @api private the source model behind a generated constant name
      def registered_source(const_name)
        MONITOR.synchronize { sources[const_name.to_s] }
      end

      def clear!
        MONITOR.synchronize do
          @cache = {}
          @sources = {}
        end
      end

      private

      def cache
        @cache ||= {}
      end

      # Constant name => source model, so Archived.const_missing can build a
      # class an association asked for.
      def sources
        @sources ||= {}
      end

      def build(source)
        table = source.table_name
        polymorphic = source.polymorphic_name

        klass = Class.new(ArchiveRecord) do
          self.table_name         = table
          self.inheritance_column = nil
          self.record_timestamps  = false
        end
        klass.primary_key = source.primary_key
        klass.source_model_name = source.name
        # So `has_many ..., as:` conditions keep matching the archived rows,
        # which store the *source* class name in their type column.
        klass.define_singleton_method(:polymorphic_name) { polymorphic }

        register(source)
        const = const_name_for(table)
        Archived.send(:remove_const, const) if Archived.const_defined?(const, false)
        Archived.const_set(const, klass)
        mirror_associations(klass, source)
        klass
      end

      def register(source)
        sources[const_name_for(source.table_name)] = source
      end

      # Redeclares the source associations against the archive classes, so an
      # archived row can be read together with its archived children.
      #
      # Deliberately dropped: dependent:, counter caches, touch and autosave -
      # an archive is a reading surface, it must not cascade anything.
      def mirror_associations(klass, source)
        source.reflect_on_all_associations.each do |reflection|
          next unless MIRRORED_MACROS.include?(reflection.macro)
          next if reflection.options[:polymorphic]

          if reflection.options[:through]
            mirror_through_association(klass, reflection)
          else
            mirror_association(klass, reflection)
          end
        end
      end

      # A through association needs no class_name: it composes out of the two
      # associations it is built on, which are mirrored too, so it stays inside
      # the archive database.
      def mirror_through_association(klass, reflection)
        # A polymorphic source would resolve to a primary-database class and
        # quietly read from the wrong database.
        return if reflection.options[:source_type]

        options = { through: reflection.options[:through] }
        options[:source] = reflection.options[:source] if reflection.options[:source]

        klass.public_send(reflection.macro, reflection.name, reflection.scope, **options)
      rescue StandardError => e
        log_skipped(klass, reflection, e)
      end

      def mirror_association(klass, reflection)
        target = reflection.klass
        return if target.abstract_class? || target.table_name.blank?

        register(target)
        klass.public_send(reflection.macro, reflection.name, portable_scope(reflection),
                          **options_for(reflection, target))
      rescue StandardError => e
        log_skipped(klass, reflection, e)
      end

      # An association scope is written against the source model, and may call
      # scopes or class methods only that model has:
      #
      #   has_many :time_periods, -> { sorted('start_time', 'asc') }
      #
      # Plain conditions carry over to the archive; anything the archive class
      # cannot evaluate falls back to the unfiltered relation rather than
      # blowing up a read.
      def portable_scope(reflection)
        scope = reflection.scope
        return nil if scope.nil?

        lambda do |*args|
          instance_exec(*args, &scope)
        rescue StandardError => e
          RecordArchiver.logger.debug do
            "#{Logging::PREFIX} ignoring the scope of #{reflection.name} on the archive model: " \
              "#{e.class}: #{e.message}"
          end
          self
        end
      end

      def log_skipped(klass, reflection, error)
        RecordArchiver.logger.debug do
          "#{Logging::PREFIX} skipping association #{klass.source_model_name}##{reflection.name} " \
            "on the archive model: #{error.class}: #{error.message}"
        end
      end

      def options_for(reflection, target)
        options = {
          class_name: "RecordArchiver::Archived::#{const_name_for(target.table_name)}",
          foreign_key: reflection.foreign_key,
          inverse_of: false
        }
        options[:primary_key] = reflection.options[:primary_key] if reflection.options[:primary_key]
        options[:as] = reflection.options[:as] if reflection.options[:as]
        options[:optional] = true if reflection.macro == :belongs_to
        options
      end

      def const_name_for(table)
        name = table.gsub(/[^A-Za-z0-9_]/, '_').camelize
        name = "T#{name}" unless name.match?(/\A[A-Z]/)
        name
      end
    end
  end
end
