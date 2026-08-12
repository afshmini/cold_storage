# frozen_string_literal: true

RSpec.describe ColdStorage::Archiver do
  before(:all) { ColdStorage.sync_schema!(models: [Invoice, Note, Tax]) }

  def create_invoice(number:, created_at: 2.years.ago, **attributes)
    Invoice.create!(number: number, created_at: created_at, updated_at: created_at, **attributes)
  end

  describe 'moving rows' do
    let!(:old_invoice) do
      create_invoice(
        number: 'old',
        state: 'paid',
        payload: { 'currency' => 'EUR', 'lines' => [1, 2] },
        tags: %w[import legacy],
        total: BigDecimal('1234.56')
      )
    end
    let!(:recent_invoice) { create_invoice(number: 'recent', created_at: 1.month.ago) }

    it 'copies the eligible rows to the archive and deletes them from the source' do
      result = Invoice.archive_now!

      expect(result.archived).to eq(1)
      expect(result.deleted).to eq(1)
      expect(Invoice.unscoped.pluck(:number)).to eq(['recent'])
      expect(Invoice.archived.pluck(:number)).to eq(['old'])
    end

    it 'keeps the primary key, so archived rows stay identifiable' do
      id = old_invoice.id
      Invoice.archive_now!

      expect(Invoice.archived.pluck(:id)).to eq([id])
    end

    it 'round-trips enum, jsonb, array and decimal values unchanged' do
      Invoice.archive_now!
      archived = Invoice.archived.first

      expect(archived.state).to eq('paid')
      expect(archived.payload).to eq('currency' => 'EUR', 'lines' => [1, 2])
      expect(archived.tags).to eq(%w[import legacy])
      expect(archived.total).to eq(BigDecimal('1234.56'))
      expect(archived.created_at).to be_within(1.second).of(old_invoice.created_at)
    end

    it 'stamps archived_at' do
      Invoice.archive_now!

      expect(Invoice.archived.first.archived_at).to be_within(1.minute).of(Time.current)
    end

    it 'is idempotent: re-archiving the same id updates instead of duplicating' do
      Invoice.archive_now!
      Invoice.unscoped.insert_all!([{ id: old_invoice.id, number: 'old', created_at: 2.years.ago,
                                      updated_at: 2.years.ago }])
      Invoice.archive_now!

      expect(Invoice.archived.count).to eq(1)
    end

    it 'reports what it would do without moving anything on a dry run' do
      result = Invoice.archive_now!(dry_run: true)

      expect(result.archived).to eq(1)
      expect(Invoice.unscoped.count).to eq(2)
      expect(Invoice.archived.count).to eq(0)
    end

    it 'can copy without deleting' do
      Invoice.archiving_policy = ColdStorage::Policy.new(Invoice, after: 12.months, delete_after_archive: false)
      result = Invoice.archive_now!

      expect(result.deleted).to eq(0)
      expect(Invoice.unscoped.count).to eq(2)
      expect(Invoice.archived.count).to eq(1)
    ensure
      Invoice.archivable after: 12.months, every: 1.month, cascade: [:invoice_lines]
    end

    it 'walks the table in batches' do
      5.times { |i| create_invoice(number: "batch-#{i}") }

      expect(Invoice.archive_now!(batch_size: 2).archived).to eq(6)
      expect(Invoice.archived.count).to eq(6)
    end

    it 'stops at the limit' do
      5.times { |i| create_invoice(number: "batch-#{i}") }

      expect(Invoice.archive_now!(limit: 3).archived).to eq(3)
      expect(Invoice.unscoped.count).to eq(4)
    end

    it 'leaves rows that are not eligible yet' do
      expect { Invoice.archive_now! }.not_to(change { Invoice.unscoped.exists?(recent_invoice.id) })
    end
  end

  describe 'soft-deleted rows' do
    before do
      Note.create!(body: 'kept')
      Note.create!(body: 'gone', deleted_at: 1.hour.ago)
    end

    it 'archives only the deleted ones' do
      Note.archive_now!

      expect(Note.pluck(:body)).to eq(['kept'])
      expect(Note.archived.pluck(:body)).to eq(['gone'])
    end
  end

  describe 'cascade' do
    let!(:invoice) { create_invoice(number: 'with-lines') }
    let(:archived_lines) { ColdStorage::ArchiveModel.for(InvoiceLine) }
    let(:archived_taxes) { ColdStorage::ArchiveModel.for(Tax) }

    before do
      line = invoice.invoice_lines.create!(description: 'work', amount: 10)
      invoice.invoice_lines.create!(description: 'travel', amount: 20)
      Tax.create!(invoice_line_id: line.id, rate: 19)
    end

    it 'archives the children before the parent, so foreign keys hold' do
      expect { Invoice.archive_now! }.not_to raise_error

      expect(InvoiceLine.count).to eq(0)
      expect(archived_lines.pluck(:description)).to contain_exactly('work', 'travel')
    end

    it 'leaves grandchildren alone unless the cascade names them' do
      Invoice.archive_now!

      expect(Tax.count).to eq(1)
      expect(archived_taxes.count).to eq(0)
    end

    it 'follows a nested cascade all the way down' do
      Invoice.archiving_policy = ColdStorage::Policy.new(
        Invoice, after: 12.months, cascade: { invoice_lines: [:taxes] }
      )

      Invoice.archive_now!

      expect(Tax.count).to eq(0)
      expect(archived_taxes.pluck(:rate)).to eq([19])
    ensure
      Invoice.archivable after: 12.months, every: 1.month, cascade: [:invoice_lines]
    end

    it 'reports a cascade association that does not exist, before moving anything' do
      Invoice.archiving_policy = ColdStorage::Policy.new(
        Invoice, after: 12.months, cascade: { invoice_lines: [:nope] }
      )

      expect { Invoice.archive_now! }
        .to raise_error(ColdStorage::InvalidPolicyError, /no association :nope/)
      expect(Invoice.unscoped.count).to eq(1)
    ensure
      Invoice.archivable after: 12.months, every: 1.month, cascade: [:invoice_lines]
    end
  end

  describe 'the every: window' do
    let!(:invoice) { create_invoice(number: 'old') }

    it 'skips a model that ran recently' do
      Invoice.archive_now!
      create_invoice(number: 'old-2')

      result = ColdStorage.archive(Invoice)

      expect(result).to be_skipped
      expect(result.reason).to eq(:not_due)
      expect(Invoice.unscoped.count).to eq(1)
    end

    it 'runs again once the window elapsed' do
      Invoice.archive_now!
      ColdStorage::Run.for_model(Invoice).update_all(finished_at: 2.months.ago)
      create_invoice(number: 'old-2')

      expect(ColdStorage.archive(Invoice)).not_to be_skipped
    end

    it 'records the run' do
      Invoice.archive_now!
      run = ColdStorage::Run.for_model(Invoice).last

      expect(run.status).to eq('succeeded')
      expect(run.archived_count).to eq(1)
      expect(run.archived_table).to eq('invoices')
    end
  end

  describe 'guard rails' do
    it 'refuses to archive a model without a policy' do
      expect { ColdStorage.archive(InvoiceLine) }
        .to raise_error(ColdStorage::NotArchivableError, /not archivable/)
    end

    it 'explains what to do when the archive table is missing' do
      Support::Schema.archive { |connection| connection.drop_table('notes', force: :cascade) }
      Note.create!(body: 'gone', deleted_at: 1.hour.ago)

      expect { Note.archive_now! }
        .to raise_error(ColdStorage::SchemaMissingError, /cold_storage:schema:sync/)
    ensure
      ColdStorage.sync_schema!(models: [Note])
    end
  end
end
