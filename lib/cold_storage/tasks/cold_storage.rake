# frozen_string_literal: true

namespace :cold_storage do
  desc 'List the archivable models, their rule, pending/archived counts and last run'
  task status: :environment do
    puts ColdStorage.report
  end

  namespace :db do
    # ActiveRecord's database tasks leave ActiveRecord::Base connected to the
    # database they just touched, which would send the rest of the process to
    # the archive. Put the primary connection back.
    def with_primary_connection_restored
      yield
    ensure
      ActiveRecord::Base.establish_connection(Rails.env.to_sym)
    end

    desc 'Create the archive database'
    task create: :environment do
      config = ColdStorage::ArchiveRecord.database_config
      abort('No archive database configured (see config/database.yml)') if config.nil?

      with_primary_connection_restored { ActiveRecord::Tasks::DatabaseTasks.create(config) }
      puts "Created #{config.database}"
    end

    desc 'Drop the archive database (asks for DISPOSABLE=1)'
    task drop: :environment do
      abort('Refusing to drop the archive database without DISPOSABLE=1') unless ENV['DISPOSABLE'] == '1'

      config = ColdStorage::ArchiveRecord.database_config
      abort('No archive database configured (see config/database.yml)') if config.nil?

      with_primary_connection_restored { ActiveRecord::Tasks::DatabaseTasks.drop(config) }
      puts "Dropped #{config.database}"
    end
  end

  namespace :schema do
    desc 'Copy/update the archive database schema for the archivable models'
    task sync: :environment do
      changes = ColdStorage.sync_schema!
      puts changes.empty? ? 'Archive schema already up to date.' : "Applied #{changes.size} change(s)."
    end

    desc 'Show what cold_storage:schema:sync would change'
    task plan: :environment do
      changes = ColdStorage.schema_drift
      if changes.empty?
        puts 'Archive schema is up to date.'
      else
        changes.each { |change| puts "  #{change}" }
      end
    end

    desc 'Exit non-zero when the archive schema drifted from the primary one (for CI)'
    task check: :environment do
      changes = ColdStorage.schema_drift.reject { |change| change.type == :extra_column }
      next puts('Archive schema is up to date.') if changes.empty?

      changes.each { |change| warn "  #{change}" }
      abort("Archive schema is #{changes.size} change(s) behind. Run rails cold_storage:schema:sync")
    end
  end

  desc 'Archive one model: rake cold_storage:archive[Payroll]'
  task :archive, %i[model] => :environment do |_task, args|
    abort('Usage: rake cold_storage:archive[ModelName]') if args[:model].blank?

    result = ColdStorage.archive(
      args[:model].constantize,
      force: ENV['FORCE'] != 'false',
      dry_run: ENV['DRY_RUN'] == 'true',
      limit: ENV['LIMIT']&.to_i
    )
    puts result
  end

  desc 'Archive every archivable model whose schedule is due'
  task archive_all: :environment do
    results = ColdStorage.archive_all(
      force: ENV['FORCE'] == 'true',
      dry_run: ENV['DRY_RUN'] == 'true'
    )
    results.each { |result| puts result }
  end

  desc 'Restore archived rows: rake cold_storage:restore[Payroll,1 2 3] (WITH=all|assoc,assoc)'
  task :restore, %i[model ids] => :environment do |_task, args|
    abort('Usage: rake cold_storage:restore[ModelName,"1 2 3"]') if args[:model].blank? || args[:ids].blank?

    with = case ENV['WITH']
           when nil, '' then nil
           when 'all' then :all
           else ENV['WITH'].split(',').map { |name| name.strip.to_sym }
           end

    count = ColdStorage.restore(args[:model].constantize, args[:ids].split.map(&:strip), with: with)
    puts "Restored #{count} row(s)."
  end
end
