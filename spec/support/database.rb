# frozen_string_literal: true

module Support
  # Connection used only to CREATE DATABASE.
  class AdminRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  # Two real PostgreSQL databases: enum types, arrays and jsonb are exactly the
  # things a schema mirror gets wrong, so the suite does not fake them.
  module Database
    SOURCE  = ENV.fetch('RA_SOURCE_DB', 'record_archiver_source_test')
    ARCHIVE = ENV.fetch('RA_ARCHIVE_DB', 'record_archiver_archive_test')

    module_function

    def base_config
      {
        'adapter'  => 'postgresql',
        'host'     => ENV.fetch('DB_HOST', 'localhost'),
        'port'     => ENV.fetch('DB_PORT', '5432'),
        'username' => ENV.fetch('POSTGRES_USER', ENV.fetch('USER', 'postgres')),
        'password' => ENV['POSTGRES_PASSWORD'],
        'encoding' => 'utf8',
        'pool'     => 5
      }
    end

    def setup!
      create_database(SOURCE)
      create_database(ARCHIVE)

      ActiveRecord::Base.configurations = {
        'test' => {
          'primary' => base_config.merge('database' => SOURCE),
          'archive' => base_config.merge('database' => ARCHIVE, 'database_tasks' => false)
        }
      }

      ActiveRecord::Base.establish_connection(:primary)
      RecordArchiver::ArchiveRecord.reset_connection!
      RecordArchiver::ArchiveRecord.connect!
    end

    def create_database(name)
      AdminRecord.establish_connection(base_config.merge('database' => 'postgres').symbolize_keys)
      AdminRecord.connection_pool.with_connection { |connection| connection.create_database(name) }
    rescue ActiveRecord::DatabaseAlreadyExists, ActiveRecord::StatementInvalid
      nil
    ensure
      AdminRecord.remove_connection
    end
  end
end
