# frozen_string_literal: true

require_relative 'lib/record_archiver/version'

Gem::Specification.new do |spec|
  spec.name        = 'record_archiver'
  spec.version     = RecordArchiver::VERSION
  spec.authors     = ['Taxmaro']
  spec.summary     = 'Declarative auto-archiving of ActiveRecord rows into a mirrored archive database.'
  spec.description = <<~DESC
    Add `archivable` to any model to move old or soft-deleted rows into a separate
    archive database. The archive database schema is mirrored from the primary one
    and kept in sync on every migration, for the archivable models only.
  DESC
  spec.license = 'MIT'

  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir[
    'lib/**/*.rb',
    'lib/**/*.rake',
    'lib/**/*.tt',
    'README.md',
    'CHANGELOG.md'
  ]
  spec.require_paths = ['lib']

  spec.add_dependency 'activerecord', '>= 7.1'
  spec.add_dependency 'activesupport', '>= 7.1'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
