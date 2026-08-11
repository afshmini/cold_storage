# frozen_string_literal: true

module RecordArchiver
  # Abstract base of everything that lives in the archive database.
  #
  # The connection is established lazily, on first use, so an application that
  # has not configured the archive database yet still boots.
  class ArchiveRecord < ActiveRecord::Base
    self.abstract_class = true

    # Name of the model in the primary database this table belongs to.
    class_attribute :source_model_name, instance_accessor: false, default: nil

    # The model in the primary database an archived row came from.
    def self.source_model
      source_model_name&.constantize
    end

    def source_model
      self.class.source_model
    end

    # Moves this row (and, with `with:`, its archived children) back into the
    # primary database.
    #
    #   Invoice.archived.find(42).restore!(with: :all)
    #
    # @return [Integer] number of restored rows
    def restore!(**options)
      model = source_model
      raise NotArchivableError, "#{self.class} has no source model" if model.nil?

      RecordArchiver.restore(model, [id], **options)
    end

    class << self
      # @return [self]
      def connect!
        return self if @connected

        MUTEX.synchronize do
          next if @connected

          database = RecordArchiver.config.archive_database.to_sym
          assert_configured!(database)
          connects_to database: { writing: database, reading: database }
          @connected = true
        end

        self
      end

      # Yields a checked out connection to the archive database.
      # (Named differently from ActiveRecord's own `with_connection` so that
      # nothing in ActiveRecord ends up calling this override.)
      def with_archive_connection(&block)
        connect!
        connection_pool.with_connection(&block)
      end

      # Forget the established connection, e.g. after changing the config in a
      # test. The pool itself is left to ActiveRecord.
      def reset_connection!
        MUTEX.synchronize { @connected = false }
      end

      def database_config
        env = current_env
        ActiveRecord::Base.configurations.configs_for(
          env_name: env,
          name: RecordArchiver.config.archive_database.to_s,
          include_hidden: true
        )
      end

      private

      MUTEX = Mutex.new
      private_constant :MUTEX

      def current_env
        if defined?(Rails) && Rails.respond_to?(:env)
          Rails.env.to_s
        else
          ENV['RAILS_ENV'].presence || ENV['RACK_ENV'].presence || 'default_env'
        end
      end

      def assert_configured!(database)
        return if database_config

        available = ActiveRecord::Base.configurations
                                      .configs_for(env_name: current_env, include_hidden: true)
                                      .map(&:name)
        raise ConfigurationError, <<~MESSAGE
          No "#{database}" database configured for the "#{current_env}" environment.
          Available entries: #{available.join(', ')}.

          Add one to config/database.yml, for example:

            #{current_env}:
              primary:
                <<: *default
              #{database}:
                <<: *default
                database: <%= ENV.fetch('ARCHIVE_POSTGRES_DB') %>
                database_tasks: false

          `database_tasks: false` keeps `rails db:migrate` from running the
          application migrations against the archive database; RecordArchiver
          mirrors the schema itself.
        MESSAGE
      end
    end
  end
end
