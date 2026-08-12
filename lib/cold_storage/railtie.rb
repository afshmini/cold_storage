# frozen_string_literal: true

module ColdStorage
  # Rails wiring: the `archivable` macro, the logger, the rake tasks, and the
  # automatic schema sync after migrations.
  class Railtie < ::Rails::Railtie
    config.cold_storage = ActiveSupport::OrderedOptions.new

    initializer 'cold_storage.model' do
      ActiveSupport.on_load(:active_record) do
        extend ColdStorage::Model
      end
    end

    initializer 'cold_storage.jobs' do
      ActiveSupport.on_load(:active_job) do
        ColdStorage::Jobs.define!
      end
    end

    initializer 'cold_storage.logger' do |app|
      app.config.after_initialize do
        ColdStorage.config.logger ||= Rails.logger
        app.config.cold_storage.each { |key, value| ColdStorage.config.public_send(:"#{key}=", value) }
      end
    end

    rake_tasks do
      load File.expand_path('tasks/cold_storage.rake', __dir__)
      ColdStorage::Railtie.hook_into_migrations!
    end

    # After the primary database changes, bring the archive schema along - for
    # the archivable models only.
    def self.hook_into_migrations!
      %w[db:migrate db:migrate:up db:migrate:down db:rollback db:schema:load].each do |name|
        next unless Rake::Task.task_defined?(name)

        Rake::Task[name].enhance do
          next unless ColdStorage.config.sync_schema_after_migrate

          sync = Rake::Task['cold_storage:schema:sync']
          sync.reenable
          sync.invoke
        rescue ColdStorage::ConfigurationError => e
          Rails.logger&.info { "#{ColdStorage::Logging::PREFIX} skipping schema sync: #{e.message}" }
        end
      end
    end
  end
end
