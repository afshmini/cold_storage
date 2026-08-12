# frozen_string_literal: true

module Support
  # The source schema the specs archive from, plus helpers to reset both
  # databases between examples.
  module Schema
    module_function

    def load!
      source do |connection|
        connection.create_enum('invoice_state', %w[draft sent paid]) if connection.respond_to?(:create_enum)

        connection.drop_table(:taxes, if_exists: true)
        connection.drop_table(:invoice_lines, if_exists: true)
        connection.drop_table(:invoices, if_exists: true)
        connection.drop_table(:notes, if_exists: true)
        connection.drop_table(:receipts, if_exists: true)

        connection.create_table(:invoices) do |t|
          t.string  :number
          t.column  :state, :invoice_state
          t.jsonb   :payload, default: {}
          t.string  :tags, array: true
          t.decimal :total, precision: 12, scale: 2
          t.datetime :deleted_at
          t.timestamps
          t.index :number, unique: true
          t.index :deleted_at
        end

        connection.create_table(:invoice_lines) do |t|
          t.references :invoice, null: false, foreign_key: true
          t.string     :description
          t.decimal    :amount, precision: 12, scale: 2
          t.timestamps
        end

        # No foreign key: the specs archive taxes on their own, and the point
        # here is the through association, not referential integrity.
        connection.create_table(:taxes) do |t|
          t.bigint  :invoice_line_id
          t.decimal :rate, precision: 5, scale: 2
          t.timestamps
          t.index :invoice_line_id
        end

        connection.create_table(:notes) do |t|
          t.string   :body
          t.datetime :deleted_at
          t.timestamps
        end

        connection.create_table(:receipts) do |t|
          t.string :reference
          t.timestamps
        end
      end

      drop_archive!
    end

    # Every archive table plus the gem's own bookkeeping, so each example
    # starts from an empty archive database.
    def drop_archive!
      archive do |connection|
        connection.tables.each { |table| connection.drop_table(table, force: :cascade) }
        connection.enum_types.each { |(name, _)| connection.drop_enum(name, if_exists: true) }
      end
    end

    def reset_data!
      source do |connection|
        connection.execute(
          'TRUNCATE taxes, invoice_lines, invoices, notes, receipts RESTART IDENTITY CASCADE'
        )
      end
      archive do |connection|
        (connection.tables - ['cold_storage_metadata']).each do |table|
          connection.execute("TRUNCATE #{connection.quote_table_name(table)} RESTART IDENTITY CASCADE")
        end
      end
    end

    def source(&block)
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end

    def archive(&block)
      ColdStorage::ArchiveRecord.with_archive_connection(&block)
    end
  end
end
