# frozen_string_literal: true

RSpec.describe 'reading archived data' do
  before(:all) { RecordArchiver.sync_schema!(models: [Invoice, Note, Tax]) }

  let!(:invoice) do
    Invoice.create!(number: 'old', state: 'paid', tags: %w[a b], total: 42,
                    created_at: 2.years.ago, updated_at: 2.years.ago)
  end
  let!(:line) { invoice.invoice_lines.create!(description: 'work', amount: 10) }
  let!(:recent) { Invoice.create!(number: 'recent') }

  before { Invoice.archive_now! }

  describe '.archived' do
    it 'is an ordinary relation on the archive database' do
      expect(Invoice.archived).to be_a(ActiveRecord::Relation)
      expect(Invoice.archived.where(number: 'old').pluck(:total)).to eq([42])
      expect(Invoice.archived.order(:id).first.number).to eq('old')
    end

    it 'counts what is in the archive' do
      expect(Invoice.archived_count).to eq(1)
    end

    it 'knows the model it came from' do
      expect(Invoice.archived.first.source_model).to eq(Invoice)
    end
  end

  describe 'associations' do
    it 'reads the archived children of an archived row' do
      archived = Invoice.archived.find(invoice.id)

      expect(archived.invoice_lines.pluck(:description)).to eq(['work'])
      expect(archived.invoice_lines.first.id).to eq(line.id)
    end

    it 'reads the archived parent of an archived child' do
      archived_line = RecordArchiver::ArchiveModel.for(InvoiceLine).find(line.id)

      expect(archived_line.invoice.number).to eq('old')
    end

    it 'never reaches back into the primary database' do
      archived = Invoice.archived.find(invoice.id)

      expect(archived.invoice_lines.first).to be_a(RecordArchiver::ArchiveRecord)
      expect(InvoiceLine.count).to eq(0)
    end

    it 'reads a has_many :through inside the archive' do
      tax = Tax.create!(invoice_line_id: line.id, rate: 19)
      RecordArchiver::Archiver.new(Tax, relation: Tax.where(id: tax.id), force: true).call

      archived = Invoice.archived.find(invoice.id)

      expect(archived.taxes.pluck(:rate)).to eq([19])
      expect(archived.taxes.first).to be_a(RecordArchiver::ArchiveRecord)
    end

    it 'eager loads like any other association' do
      archived = Invoice.archived.includes(:invoice_lines).find(invoice.id)

      expect(archived.invoice_lines.loaded?).to be(true)
    end
  end

  describe '.find_archived' do
    it 'finds by id' do
      expect(Invoice.find_archived(invoice.id).number).to eq('old')
    end

    it 'raises when the row is not archived' do
      expect { Invoice.find_archived(recent.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe '.find_with_archived' do
    it 'finds a live record' do
      expect(Invoice.find_with_archived(recent.id)).to eq(recent)
    end

    it 'falls back to the archive' do
      found = Invoice.find_with_archived(invoice.id)

      expect(found.number).to eq('old')
      expect(found).to be_a(RecordArchiver::ArchiveRecord)
    end

    it 'raises when it is nowhere' do
      expect { Invoice.find_with_archived(0) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
