# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'active_record'
require 'record_archiver'
require 'logger'

require_relative 'support/database'
require_relative 'support/schema'
require_relative 'support/models'

RSpec.configure do |config|
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :defined

  config.before(:suite) do
    Support::Database.setup!
    Support::Schema.load!
  end

  config.before do
    RecordArchiver.reset_config!
    RecordArchiver.config.logger = Logger.new(IO::NULL)
    RecordArchiver::ArchiveModel.clear!
    Support::Schema.reset_data!
  end
end
