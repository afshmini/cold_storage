# frozen_string_literal: true

require 'rails/generators/base'

module ColdStorage
  module Generators
    # rails generate cold_storage:install
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc 'Creates the ColdStorage initializer and prints the database.yml snippet.'

      def create_initializer
        template 'initializer.rb.tt', 'config/initializers/cold_storage.rb'
      end

      def show_database_instructions
        say <<~MESSAGE

          Add the archive database to config/database.yml, in every environment
          that should archive (note `database_tasks: false`, it keeps `rails
          db:migrate` from applying your migrations to the archive database):

            #{ColdStorage.config.archive_database}:
              <<: *default
              database: <%= ENV.fetch('ARCHIVE_POSTGRES_DB') %>
              database_tasks: false

          Then:

            rails cold_storage:db:create
            rails cold_storage:schema:sync
            rails cold_storage:status

        MESSAGE
      end
    end
  end
end
