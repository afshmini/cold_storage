# frozen_string_literal: true

module RecordArchiver
  # Rails wiring: the `archivable` macro, the logger, the rake tasks, and the
  # automatic schema sync after migrations.
  class Railtie < ::Rails::Railtie
    config.record_archiver = ActiveSupport::OrderedOptions.new

    initializer 'record_archiver.model' do
      ActiveSupport.on_load(:active_record) do
        extend RecordArchiver::Model
      end
    end

    initializer 'record_archiver.jobs' do
      ActiveSupport.on_load(:active_job) do
        RecordArchiver::Jobs.define!
      end
    end

    initializer 'record_archiver.logger' do |app|
      app.config.after_initialize do
        RecordArchiver.config.logger ||= Rails.logger
        app.config.record_archiver.each { |key, value| RecordArchiver.config.public_send(:"#{key}=", value) }
      end
    end

    rake_tasks do
      load File.expand_path('tasks/record_archiver.rake', __dir__)
      RecordArchiver::Railtie.hook_into_migrations!
    end

    # After the primary database changes, bring the archive schema along - for
    # the archivable models only.
    def self.hook_into_migrations!
      %w[db:migrate db:migrate:up db:migrate:down db:rollback db:schema:load].each do |name|
        next unless Rake::Task.task_defined?(name)

        Rake::Task[name].enhance do
          next unless RecordArchiver.config.sync_schema_after_migrate

          sync = Rake::Task['record_archiver:schema:sync']
          sync.reenable
          sync.invoke
        rescue RecordArchiver::ConfigurationError => e
          Rails.logger&.info { "#{RecordArchiver::Logging::PREFIX} skipping schema sync: #{e.message}" }
        end
      end
    end
  end
end
