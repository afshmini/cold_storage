# frozen_string_literal: true

module RecordArchiver
  # Shared, prefixed logging.
  module Logging
    PREFIX = '[RecordArchiver]'

    private

    def log(message, level: :info)
      RecordArchiver.logger.public_send(level) { "#{PREFIX} #{message}" }
    end

    def warn_log(message)
      log(message, level: :warn)
    end
  end
end
