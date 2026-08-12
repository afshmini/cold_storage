# frozen_string_literal: true

module ColdStorage
  # ActiveJob entry points.
  #
  # The classes are built on first use (or when ActiveJob loads) so that the
  # gem does not force ActiveJob on applications that do not use it, and so
  # that `config.job_parent_class` is honoured.
  #
  #   ColdStorage::ArchiveModelJob.perform_later('Payroll')
  #   ColdStorage::ArchiveAllJob.perform_later
  module Jobs
    JOBS = %i[ArchiveModelJob ArchiveAllJob].freeze

    class << self
      # @return [Boolean] whether the job classes exist now
      def define!
        return false unless defined?(ActiveJob::Base)
        return true if ColdStorage.const_defined?(:ArchiveModelJob, false)

        parent = ColdStorage.config.job_parent_class.constantize
        ColdStorage.const_set(:ArchiveModelJob, build_model_job(parent))
        ColdStorage.const_set(:ArchiveAllJob, build_all_job(parent))
        true
      end

      private

      # Archives one model.
      def build_model_job(parent)
        Class.new(parent) do
          queue_as { ColdStorage.config.job_queue }

          def perform(model_name, **options)
            ColdStorage.archive(model_name.to_s.constantize, **options.symbolize_keys)
          end
        end
      end

      # Fans out over every archivable model. Models whose `every:` window has
      # not elapsed skip themselves, so this is safe to schedule daily.
      def build_all_job(parent)
        Class.new(parent) do
          queue_as { ColdStorage.config.job_queue }

          def perform(**options)
            ColdStorage.models.each do |model|
              ColdStorage::ArchiveModelJob.perform_later(model.name, **options.symbolize_keys)
            end
          end
        end
      end
    end
  end

  def self.const_missing(name)
    return super unless Jobs::JOBS.include?(name) && Jobs.define!

    const_get(name)
  end
end
