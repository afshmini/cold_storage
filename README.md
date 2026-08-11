# RecordArchiver

Declarative auto-archiving for ActiveRecord.

Add one line to a model and its old (or soft-deleted) rows move, on a schedule,
into a **separate archive database** whose schema is a mirror of the primary
one — created for you, and kept up to date on every migration, for the
archivable models only.

```ruby
class Payroll < ApplicationRecord
  archivable after: 18.months, every: 1.month
end

class Document < ApplicationRecord
  archivable deleted: true, after: 30.days      # soft-deleted 30+ days ago
end

class Receipt < ApplicationRecord
  archivable on_destroy: true                   # keep hard-deleted rows
end

class Invoice < ApplicationRecord
  archivable after: 2.years, cascade: [:invoice_lines]
end
```

## Installation

```ruby
# Gemfile
gem 'record_archiver', git: 'git@github.com:afshmini/rails-archiver.git'
# or, while working on it:
gem 'record_archiver', path: '../rails-archiver'
```

```bash
rails generate record_archiver:install
```

### 1. Add the archive database

`config/database.yml`, in every environment that should archive:

```yaml
development:
  primary:
    <<: *default
  archive:
    <<: *default
    database: <%= ENV.fetch('ARCHIVE_POSTGRES_DB') %>
    database_tasks: false
```

`database_tasks: false` matters: it stops `rails db:migrate` from running your
application migrations against the archive database. RecordArchiver mirrors the
schema itself, and only for the tables it needs.

### 2. Create it and mirror the schema

```bash
rails record_archiver:db:create     # CREATE DATABASE
rails record_archiver:schema:sync   # copy the archivable models' tables
rails record_archiver:status
```

### 3. Schedule it

The bundled job walks every archivable model and lets each one decide whether
its `every:` window has elapsed, so a daily schedule is enough:

```yaml
# config/recurring.yml (solid_queue)
record_archiver:
  schedule: "0 2 * * *"
  class: "RecordArchiver::ArchiveAllJob"
```

Or from cron/rake: `rails record_archiver:archive_all`.

## The `archivable` options

| Option | Meaning | Default |
| --- | --- | --- |
| `after:` (alias `older_than:`) | archive rows older than this duration | — |
| `on:` | column the age is measured on | `:created_at`, or the deleted column when `deleted: true` |
| `deleted:` | archive soft-deleted rows only | `false` |
| `deleted_column:` | where the soft-delete timestamp lives | `config.deleted_column` (`:deleted_at`) |
| `on_destroy:` (alias `hard_delete:`) | copy a row to the archive whenever it is really destroyed | `false` |
| `every:` | minimum time between two runs of this model | run on every pass |
| `scope:` | symbol, proc or relation narrowing the selection | — |
| `cascade:` | `has_many` / `has_one` names archived with the parent, nestable | `[]` |
| `batch_size:` | rows per round trip | `config.batch_size` (1000) |
| `delete_after_archive:` | remove the source rows once copied | `true` |
| `delete_method:` | `:delete_all` or `:destroy_all` | `:delete_all` |

At least one of `after:`, `deleted:`, `scope:` or `on_destroy:` is required —
without a criterion the whole table would be archivable, which is never what
you meant.

```ruby
archivable after: 12.months                                # by age
archivable after: 90.days, on: :closed_at                  # by another column
archivable deleted: true                                   # soft-deleted rows
archivable deleted: true, after: 30.days                   # ... after a grace period
archivable on_destroy: true                                # hard deletes
archivable after: 5.years, on_destroy: true                # both
archivable after: 5.years, every: 1.month                  # ... at most monthly
archivable after: 1.year, scope: -> { where(exported: true) }
archivable after: 2.years, cascade: [:items], batch_size: 5_000
archivable after: 2.years, cascade: [{ items: [:taxes, :notes] }, :comments]
```

`cascade:` takes a name, an array, or a nested hash, as deep as the graph goes.
Children are archived and deleted before their parents, so foreign keys hold at
every step, and anything the cascade does not name is left behind — which for a
child with a `NOT NULL` foreign key means the parent's delete fails, loudly.
Association scopes are ignored on the way down: every row pointing at the
parent is taken, never a subset, so nothing is orphaned.

The selection always starts from `unscoped`, so a soft-delete `default_scope`
cannot hide the very rows you asked to archive.

## Soft delete, hard delete, both

Three different things can make a row disappear, and each has its own switch:

* **it got old** — `after:` sweeps it on a schedule and then deletes it from
  the primary database;
* **it was soft-deleted** — `deleted: true` picks up rows whose `deleted_at`
  is set (optionally after a grace period with `after:`);
* **it is being hard-deleted right now** — `on_destroy: true` copies the row to
  the archive in a `before_destroy` hook, so `destroy`, `destroy!` and
  `destroy_all` keep a copy instead of losing one.

```ruby
class Receipt < ApplicationRecord
  archivable on_destroy: true                  # nothing swept, deletes kept
end

class Payroll < ApplicationRecord
  archivable after: 18.months, on_destroy: true # aged out *and* deleted early
end
```

`on_destroy:` on its own means "react to deletes", not "archive this table":
a scheduled run reports the model as skipped (`:destroy_only`) and
`archivable_records` is empty, so nothing is swept behind your back.

Worth knowing:

* `delete`, `delete_all` and database-level `ON DELETE CASCADE` do not run
  callbacks, so they cannot be captured. Use `destroy`/`destroy_all`, or
  `dependent: :destroy` on the parent, for rows you must keep.
* The parent's `cascade:` comes along, because `dependent: :destroy` children
  are about to go too. Nothing is deleted by the hook itself: the destroy that
  triggered it is what removes the rows, so `dependent:` keeps deciding what
  happens to the children (and a rolled-back destroy loses nothing).
* If the archive database cannot be reached, the destroy fails
  (`config.on_destroy_error = :raise`, the default): losing the row is worse
  than failing the delete. Set it to `:log` to let deletes through and only
  record the problem.
* The copy is written before the surrounding transaction commits, so a
  rolled-back destroy can leave a copy in the archive. It is keyed by primary
  key, so the row is still identifiable and a later real archive overwrites it.
* Each destroyed record is one round trip to the archive database; mass
  cleanups are better served by the scheduled sweep.

## What you get on the model

```ruby
Payroll.archivable_records      # relation of rows eligible right now
Payroll.archivable_count
Payroll.archive_now!            # archive immediately, ignoring every:
payroll.archive!                # a single record (with its cascade)
payroll.archived?

RecordArchiver.archive(Payroll)                 # honours every:
RecordArchiver.archive(Payroll, dry_run: true)  # report, move nothing
RecordArchiver.archive_all
```

## Reading archived data

```ruby
Payroll.archived                       # relation on the archive database
Payroll.archived.where(year: 2019).order(:id).pluck(:total)
Payroll.archived_count
Payroll.find_archived(42)              # RecordNotFound if it is not archived
Payroll.find_with_archived(42)         # live record, or the archived one
```

`archived` is an ordinary relation on a class connected to the archive
database, so scopes, `where`, `pluck`, `find_each` and `includes` all work.
**The model's associations are mirrored onto it**, pointing at the archive
database, so an archived row can be read together with its archived children:

```ruby
invoice = Invoice.archived.find(42)
invoice.invoice_lines                  # archived lines, from the archive DB
invoice.taxes                          # has_many :through works too
Invoice.archived.includes(:invoice_lines).find_each { |i| ... }

line = RecordArchiver.archived_model(InvoiceLine).find(7)
line.invoice                           # ... and back up
line.source_model                      # => InvoiceLine
```

Mirrored: `has_many`, `has_one`, `belongs_to` and `:through`. Not mirrored:
polymorphic `belongs_to`, and `:through` with a `source_type:` — both would
have to resolve a class name back into the primary database, and reading would
silently cross into it. `dependent:`, counter caches and `touch` are dropped on
purpose: the archive is a reading surface and must not cascade anything.

Joins between the two databases are not possible — they are separate
connections.

## Recovering

```ruby
RecordArchiver.restore(Payroll, [1, 2, 3])
Payroll.restore_archived([1, 2, 3])                       # same thing
Payroll.restore_archived(Payroll.archived.where(year: 2019))
Invoice.archived.find(42).restore!                        # from the row itself

# ... with its relations
Invoice.restore_archived([42], with: :all)                # every archived child
Invoice.restore_archived([42], with: [:invoice_lines])    # named relations
Invoice.restore_archived([42], with: { invoice_lines: [:taxes] })  # nested
Invoice.archived.find(42).restore!(with: :all)

# keep the archived copy instead of moving the rows
Invoice.restore_archived([42], with: :all, delete_from_archive: false)
```

Rows are written to the primary database parent-first, so foreign keys hold at
every step, and the archived copies are removed as they land. The return value
is the number of restored rows, children included.

`with: :all` walks every `has_many`/`has_one` that has an archive table,
recursively, cutting cycles as it goes. Named associations are checked before
anything is written, so a typo cannot leave half a graph behind. A `belongs_to`
is refused: restore the owner first, then its children — restoring a child
whose parent is still archived would fail on the foreign key.

```
rails record_archiver:restore[Invoice,"42 43"] WITH=all
rails record_archiver:restore[Invoice,"42"]    WITH=invoice_lines,taxes
```

## Rake tasks

```
rails record_archiver:status                 # models, rules, pending/archived counts, last run
rails record_archiver:db:create              # create the archive database
rails record_archiver:schema:sync            # create/update the mirrored tables
rails record_archiver:schema:plan            # what sync would change
rails record_archiver:schema:check           # exit 1 on drift (for CI)
rails record_archiver:archive[Payroll]       # one model, now
rails record_archiver:archive_all            # every model whose every: elapsed
rails record_archiver:restore[Payroll,"1 2"] # move rows back (WITH=all)
```

`DRY_RUN=true`, `LIMIT=1000` and `FORCE=true` are honoured by the archive tasks.

## Schema mirroring

`record_archiver:schema:sync` walks the archivable models (plus the tables they
cascade into) and, in the archive database:

* creates missing tables, column by column, with the same SQL types —
  including PostgreSQL enum types, arrays and `jsonb`;
* keeps the primary key, so re-archiving a row updates it instead of
  duplicating it;
* mirrors indexes;
* adds an `archived_at` column (configurable, `nil` disables it);
* adds columns that later migrations introduced;
* records the migration version it synced against.

and deliberately does **not**:

* copy foreign keys — an archive holds partial object graphs;
* copy `NOT NULL` or defaults — a schema that gets stricter later must not
  reject rows that were archived before that (`mirror_null_constraints`,
  `mirror_defaults` if you disagree);
* drop columns the primary database dropped — archived rows keep the columns
  they were archived with (`drop_removed_columns` if you disagree).

It runs automatically after `db:migrate`, `db:rollback` and `db:schema:load`
(`config.sync_schema_after_migrate`). In CI, `record_archiver:schema:check`
fails the build when a migration changed an archivable table and the archive
database was not brought along.

Column type changes are reported, not applied, unless you ask:
`config.on_type_mismatch = :warn | :raise | :change | :ignore`.

## How a row moves

Two databases cannot share a transaction, so each batch is:

1. read from the primary database, cast by the **database** column types (model
   level serializers, enums and default scopes are bypassed on both sides, so
   what lands in the archive is byte-for-byte what was in the source column);
2. `upsert`ed into the archive database, keyed on the primary key — a retry can
   never duplicate a row;
3. deleted from the primary database.

A crash between 2 and 3 leaves the row in both databases; the next run upserts
it again and deletes it. Archiving is at-least-once, and never loses a row.

With `cascade:`, children are archived and deleted **before** their parent, so
foreign keys in the primary database hold at every step.

`delete_method: :delete_all` (the default) skips callbacks by design: `after_destroy`
hooks that notify, bill or cascade should not fire because a row aged out. Use
`:destroy_all` when you do want them.

## Scheduling and `every:`

Every successful run is recorded in `record_archiver_runs` **in the archive
database**, and `every:` is checked against it. This means the cadence survives
restarts and deploys, and two workers running `archive_all` on the same day do
not archive twice.

`RecordArchiver::ArchiveAllJob` enqueues one `ArchiveModelJob` per model, so a
big table cannot starve the others.

## Configuration

```ruby
RecordArchiver.configure do |config|
  config.enabled                   = !Rails.env.test?
  config.archive_database          = :archive
  config.batch_size                = 1_000
  config.timestamp_column          = :created_at
  config.deleted_column            = :deleted_at
  config.archived_at_column        = :archived_at   # nil to disable
  config.delete_after_archive      = true
  config.delete_method             = :delete_all
  config.mirror_indexes            = true
  config.mirror_null_constraints   = false
  config.mirror_defaults           = false
  config.drop_removed_columns      = false
  config.on_type_mismatch          = :warn
  config.on_destroy_error          = :raise         # or :log
  config.sync_schema_after_migrate = true
  config.throttle                  = 0              # seconds between batches
  config.job_queue                 = :default
  config.job_parent_class          = 'ApplicationJob'
  config.dry_run                   = false
end
```

`config.enabled = false` stands everything down: scheduled runs report
themselves as skipped and the `on_destroy` hook does nothing. That is usually
what you want in the test environment, where there is no archive database and
specs destroy records all the time. Schema tasks keep working either way, so
`record_archiver:schema:check` still guards CI.

## Requirements and limits

* Rails 7.1+, Ruby 3.1+. Developed and tested against PostgreSQL; the enum
  mirroring is PostgreSQL specific and simply does nothing elsewhere.
* Models need a single-column primary key.
* Custom PostgreSQL types other than enums (domains, composites) are not
  mirrored.
* Views, functions and triggers are not mirrored.
* `cascade:` supports `has_many`/`has_one`, including polymorphic children;
  `:through` associations are rejected.

## Tests

The suite runs against two real PostgreSQL databases, because enums, arrays and
`jsonb` are exactly what a schema mirror gets wrong.

```bash
bundle install
bundle exec rspec
```

It reads `DB_HOST`, `DB_PORT`, `POSTGRES_USER` and `POSTGRES_PASSWORD`, and
creates `record_archiver_source_test` / `record_archiver_archive_test`.

To run it against the PostgreSQL of an app that already has a container, copy
the gem in and borrow that app's bundle:

```bash
docker cp . <app-container>:/tmp/ra
docker exec -w /tmp/ra <app-container> \
  bash -lc 'BUNDLE_GEMFILE=/path/to/app/Gemfile bundle exec rspec'
```
