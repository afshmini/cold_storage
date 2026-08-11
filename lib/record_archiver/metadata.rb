# frozen_string_literal: true

module RecordArchiver
  # Key/value store in the archive database. Holds the migration version the
  # mirrored schema was last synced against.
  class Metadata < ArchiveRecord
    self.table_name = InternalSchema::METADATA_TABLE
    self.primary_key = 'key'

    SCHEMA_VERSION_KEY = 'schema_version'

    class << self
      def get(key)
        InternalSchema.ensure!
        where(key: key.to_s).pick(:value)
      end

      def set(key, value)
        InternalSchema.ensure!
        upsert({ key: key.to_s, value: value.to_s, updated_at: Time.current }, unique_by: :key)
        value
      end

      def schema_version
        get(SCHEMA_VERSION_KEY)
      end

      def schema_version=(version)
        set(SCHEMA_VERSION_KEY, version)
      end
    end
  end
end
