# frozen_string_literal: true

module RecordArchiver
  # Human readable status of every archivable model: what its rule is, how many
  # rows are waiting, how many are already archived, when it last ran.
  class Report
    HEADERS = ['Model', 'Rule', 'Pending', 'Archived', 'Last run'].freeze

    def initialize(models: nil, counts: true)
      @models = models || RecordArchiver.models
      @counts = counts
    end

    def rows
      @rows ||= @models.map { |model| row_for(model) }
    end

    def to_s
      table = [HEADERS, *rows]
      widths = HEADERS.each_index.map { |i| table.map { |row| row[i].to_s.length }.max }
      separator = widths.map { |width| '-' * width }.join('-+-')

      lines = table.map { |row| row.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i]) }.join(' | ') }
      lines.insert(1, separator)
      lines.join("\n")
    end

    private

    def row_for(model)
      [
        model.name,
        model.archiving_policy.to_s,
        count { model.archivable_records.count },
        count { model.archived.count },
        Run.last_success_at(model)&.strftime('%Y-%m-%d %H:%M') || 'never'
      ]
    rescue StandardError => e
      [model.name, 'error', e.class.to_s, '-', '-']
    end

    def count
      return '-' unless @counts

      yield
    rescue ActiveRecord::StatementInvalid
      'n/a'
    end
  end
end
