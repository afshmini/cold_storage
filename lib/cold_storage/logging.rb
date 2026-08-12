# frozen_string_literal: true

module ColdStorage
  # Shared, prefixed logging.
  module Logging
    PREFIX = '[ColdStorage]'

    private

    def log(message, level: :info)
      ColdStorage.logger.public_send(level) { "#{PREFIX} #{message}" }
    end

    def warn_log(message)
      log(message, level: :warn)
    end
  end
end
