# frozen_string_literal: true

RSpec.describe ColdStorage do
  before(:all) { described_class.sync_schema!(models: [Invoice, Note, Receipt]) }

  describe '.models' do
    it 'lists the models that declared archivable' do
      expect(described_class.models).to include(Invoice, Note)
    end

    it 'does not list models without a policy' do
      expect(described_class.models).not_to include(InvoiceLine)
    end
  end

  describe 'the archivable trait' do
    it 'answers archivable? on every model' do
      expect(Invoice.archivable?).to be(true)
      expect(InvoiceLine.archivable?).to be(false)
    end

    it 'exposes the eligible rows' do
      Invoice.create!(number: 'old', created_at: 2.years.ago, updated_at: 2.years.ago)
      Invoice.create!(number: 'new')

      expect(Invoice.archivable_count).to eq(1)
      expect(Invoice.archivable_records.pluck(:number)).to eq(['old'])
    end

    it 'archives a single record' do
      invoice = Invoice.create!(number: 'one-off', created_at: 2.years.ago, updated_at: 2.years.ago)

      invoice.archive!

      expect(Invoice.unscoped.count).to eq(0)
      expect(Invoice.archived.pluck(:number)).to eq(['one-off'])
    end
  end

  describe '.report' do
    it 'summarises every archivable model' do
      Invoice.create!(number: 'old', created_at: 2.years.ago, updated_at: 2.years.ago)

      report = described_class.report

      expect(report).to include('Invoice', 'Note', 'Pending', 'created_at <', 'never')
    end
  end

  describe 'the master switch' do
    # after the suite's own reset_config!, which runs before every example
    before { described_class.config.enabled = false }

    it 'skips scheduled runs' do
      Invoice.create!(number: 'old', created_at: 2.years.ago, updated_at: 2.years.ago)

      result = Invoice.archive_now!

      expect(result).to be_skipped
      expect(result.reason).to eq(:disabled)
      expect(Invoice.unscoped.count).to eq(1)
    end

    it 'stands the destroy hook down' do
      Receipt.create!(reference: 'R-1').destroy!

      expect(ColdStorage::ArchiveModel.for(Receipt).count).to eq(0)
    end
  end

  describe 'a missing archive database' do
    it 'explains how to configure it' do
      described_class.config.archive_database = :nowhere
      ColdStorage::ArchiveRecord.reset_connection!

      expect { ColdStorage::ArchiveRecord.connect! }
        .to raise_error(ColdStorage::ConfigurationError, /No "nowhere" database configured/)
    ensure
      described_class.config.archive_database = :archive
      ColdStorage::ArchiveRecord.reset_connection!
      ColdStorage::ArchiveRecord.connect!
    end
  end
end
