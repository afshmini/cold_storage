# frozen_string_literal: true

require 'set'

module RecordArchiver
  # Keeps track of the models that called `archivable`.
  #
  # Model names are stored as strings, never as class objects, so that code
  # reloading in development does not pin stale constants.
  module Registry
    MUTEX = Mutex.new
    private_constant :MUTEX

    class << self
      def register(model)
        MUTEX.synchronize { names << model.name } if model.name
        model
      end

      def registered?(model)
        MUTEX.synchronize { names.include?(model.to_s) }
      end

      # @return [Array<String>]
      def model_names(eager_load: true)
        load_application! if eager_load
        MUTEX.synchronize { names.to_a }.sort
      end

      # @return [Array<Class>] the archivable models, skipping names that no
      #   longer resolve (removed or renamed classes).
      def models(eager_load: true)
        model_names(eager_load: eager_load).filter_map do |name|
          klass = name.safe_constantize
          klass if klass.respond_to?(:archivable?) && klass.archivable?
        end
      end

      def clear!
        MUTEX.synchronize { @names = Set.new }
      end

      private

      def names
        @names ||= Set.new
      end

      def load_application!
        return if @eager_loaded
        return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        Rails.application.eager_load!
        @eager_loaded = true
      rescue StandardError => e
        RecordArchiver.logger.warn { "#{Logging::PREFIX} eager load failed: #{e.class}: #{e.message}" }
      end
    end
  end
end
