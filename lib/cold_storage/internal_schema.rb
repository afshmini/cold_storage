# frozen_string_literal: true

module ColdStorage
  # The gem's own tables inside the archive database. They are created on
  # demand: the archive database needs no migrations of its own.
  module InternalSchema
    RUNS_TABLE     = 'cold_storage_runs'
    METADATA_TABLE = 'cold_storage_metadata'

    class << self
      def ensure!
        ArchiveRecord.with_archive_connection do |connection|
          create_runs_table(connection)
          create_metadata_table(connection)
        end
        true
      end

      def ready?
        ArchiveRecord.with_archive_connection do |connection|
          connection.table_exists?(RUNS_TABLE) && connection.table_exists?(METADATA_TABLE)
        end
      end

      private

      def create_runs_table(connection)
        return if connection.table_exists?(RUNS_TABLE)

        connection.create_table(RUNS_TABLE) do |t|
          t.string   :archived_model, null: false
          t.string   :archived_table
          t.string   :status, null: false, default: 'running'
          t.integer  :archived_count, null: false, default: 0
          t.integer  :deleted_count, null: false, default: 0
          t.datetime :started_at
          t.datetime :finished_at
          t.text     :error_message
          t.timestamps
        end
        connection.add_index(RUNS_TABLE, %i[archived_model status finished_at],
                             name: 'index_cold_storage_runs_on_model_and_status')
      end

      def create_metadata_table(connection)
        return if connection.table_exists?(METADATA_TABLE)

        connection.create_table(METADATA_TABLE, id: false) do |t|
          t.string   :key, null: false, primary_key: true
          t.text     :value
          t.datetime :updated_at
        end
      end
    end
  end
end
