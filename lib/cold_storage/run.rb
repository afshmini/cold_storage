# frozen_string_literal: true

module ColdStorage
  # One archiving run of one model. Lives in the archive database, and is what
  # makes the `every:` option work across processes and deploys.
  class Run < ArchiveRecord
    self.table_name = InternalSchema::RUNS_TABLE

    STATUSES = %w[running succeeded failed].freeze

    scope :succeeded, -> { where(status: 'succeeded') }
    scope :for_model, ->(model) { where(archived_model: model.to_s) }

    class << self
      # @return [Time, nil] when the model was last archived successfully
      def last_success_at(model)
        InternalSchema.ensure!
        for_model(model).succeeded.maximum(:finished_at)
      end

      def start!(model)
        InternalSchema.ensure!
        create!(
          archived_model: model.to_s,
          archived_table: (model.table_name if model.respond_to?(:table_name)),
          status: 'running',
          started_at: Time.current
        )
      end
    end

    def succeed!(archived_count:, deleted_count:)
      update!(
        status: 'succeeded',
        archived_count: archived_count,
        deleted_count: deleted_count,
        finished_at: Time.current
      )
    end

    def fail!(error, archived_count: 0, deleted_count: 0)
      update!(
        status: 'failed',
        archived_count: archived_count,
        deleted_count: deleted_count,
        finished_at: Time.current,
        error_message: "#{error.class}: #{error.message}"
      )
    end
  end
end
