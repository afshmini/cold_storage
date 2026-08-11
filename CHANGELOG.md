# Changelog

## 0.1.0

* `archivable` macro: `after:`, `on:`, `deleted:`, `deleted_column:`,
  `on_destroy:`, `every:`, `scope:`, `cascade:`, `batch_size:`,
  `delete_after_archive:`, `delete_method:`.
* `on_destroy: true` keeps hard-deleted rows by copying them to the archive in
  a `before_destroy` hook, together with the policy's cascade and without
  deleting anything itself; `config.on_destroy_error` decides whether an
  unreachable archive blocks the delete.
* `cascade:` accepts a nested tree (`cascade: { lines: [:taxes] }`) so a whole
  object graph can be taken along, validated before anything moves.
* Separate archive database, connected lazily through `RecordArchiver::ArchiveRecord`.
* Schema mirroring for the archivable models only, including PostgreSQL enum
  types, arrays and indexes; automatic sync after `db:migrate`, and a
  `record_archiver:schema:check` task for CI.
* Batched, idempotent archiving with cascade support, dry runs and limits.
* Reading: `Model.archived`, `archived_count`, `find_archived`,
  `find_with_archived`, and archive models that mirror the source
  associations (`has_many`, `has_one`, `belongs_to`, `:through`) so an archived
  row can be read together with its archived children.
* Restore back into the primary database, on its own or with relations:
  `with: :all`, `with: [:lines]`, `with: { lines: [:taxes] }`, from
  `Model.restore_archived` or from an archived record's `restore!`.
* Run bookkeeping in the archive database, which is what makes `every:` work
  across processes.
* `RecordArchiver::ArchiveAllJob` / `ArchiveModelJob` and the
  `record_archiver:*` rake tasks.
