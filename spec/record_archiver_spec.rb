# frozen_string_literal: true

RSpec.describe RecordArchiver do
  before(:all) { described_class.sync_schema!(models: [Invoice, Note]) }

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

  describe 'a missing archive database' do
    it 'explains how to configure it' do
      described_class.config.archive_database = :nowhere
      RecordArchiver::ArchiveRecord.reset_connection!

      expect { RecordArchiver::ArchiveRecord.connect! }
        .to raise_error(RecordArchiver::ConfigurationError, /No "nowhere" database configured/)
    ensure
      described_class.config.archive_database = :archive
      RecordArchiver::ArchiveRecord.reset_connection!
      RecordArchiver::ArchiveRecord.connect!
    end
  end
end
