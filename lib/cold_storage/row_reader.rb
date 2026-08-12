# frozen_string_literal: true

module ColdStorage
  # Reads rows as plain hashes, cast by the *database* column types rather than
  # by the model's attribute types.
  #
  # This is what makes a copy faithful: model level serializers, enums and
  # default scopes are bypassed on both sides, while jsonb stays a Hash, arrays
  # stay Arrays and numerics stay BigDecimals - so the same values are written
  # back into identically typed columns on the other side.
  module RowReader
    private

    # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    # @param sql [String]
    # @return [Array<Hash{String => Object}>]
    def select_rows_as_hashes(connection, sql, name)
      result = connection.select_all(sql, name)
      return [] if result.empty?

      columns = result.columns
      values = result.cast_values

      if columns.size == 1
        values.map { |value| { columns.first => value } }
      else
        values.map { |row| columns.zip(row).to_h }
      end
    end
  end
end
