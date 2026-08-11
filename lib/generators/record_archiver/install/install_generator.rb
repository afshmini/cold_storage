# frozen_string_literal: true

require 'rails/generators/base'

module RecordArchiver
  module Generators
    # rails generate record_archiver:install
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc 'Creates the RecordArchiver initializer and prints the database.yml snippet.'

      def create_initializer
        template 'initializer.rb.tt', 'config/initializers/record_archiver.rb'
      end

      def show_database_instructions
        say <<~MESSAGE

          Add the archive database to config/database.yml, in every environment
          that should archive (note `database_tasks: false`, it keeps `rails
          db:migrate` from applying your migrations to the archive database):

            #{RecordArchiver.config.archive_database}:
              <<: *default
              database: <%= ENV.fetch('ARCHIVE_POSTGRES_DB') %>
              database_tasks: false

          Then:

            rails record_archiver:db:create
            rails record_archiver:schema:sync
            rails record_archiver:status

        MESSAGE
      end
    end
  end
end
