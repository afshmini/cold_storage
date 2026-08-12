# frozen_string_literal: true

RSpec.describe ColdStorage::Restorer do
  before(:all) { ColdStorage.sync_schema!(models: [Invoice, Note, Tax]) }

  let!(:invoice) do
    Invoice.create!(number: 'old', state: 'sent', tags: ['a'], total: 9.99,
                    created_at: 2.years.ago, updated_at: 2.years.ago)
  end

  before { Invoice.archive_now! }

  it 'moves rows back into the primary database' do
    expect(ColdStorage.restore(Invoice, [invoice.id])).to eq(1)

    restored = Invoice.unscoped.find(invoice.id)
    expect(restored.number).to eq('old')
    expect(restored.state).to eq('sent')
    expect(restored.tags).to eq(['a'])
    expect(restored.total).to eq(BigDecimal('9.99'))
  end

  it 'removes them from the archive' do
    ColdStorage.restore(Invoice, [invoice.id])

    expect(Invoice.archived.count).to eq(0)
  end

  it 'does not carry the archived_at stamp back' do
    ColdStorage.restore(Invoice, [invoice.id])

    expect(Invoice.unscoped.find(invoice.id).attributes).not_to have_key('archived_at')
  end

  it 'accepts an archive relation' do
    expect(ColdStorage.restore(Invoice, Invoice.archived.where(number: 'old'))).to eq(1)
    expect(Invoice.unscoped.count).to eq(1)
  end

  it 'can keep the archived copy' do
    ColdStorage.restore(Invoice, [invoice.id], delete_from_archive: false)

    expect(Invoice.archived.count).to eq(1)
    expect(Invoice.unscoped.count).to eq(1)
  end

  it 'restores from the archived record itself' do
    Invoice.archived.find(invoice.id).restore!

    expect(Invoice.unscoped.count).to eq(1)
  end

  it 'restores through the model' do
    expect(Invoice.restore_archived([invoice.id])).to eq(1)
  end

  describe 'with relations' do
    let(:archived_lines) { ColdStorage::ArchiveModel.for(InvoiceLine) }

    before do
      Invoice.unscoped.find_each(&:destroy)
      Support::Schema.reset_data!

      invoice = Invoice.create!(number: 'with-lines', created_at: 2.years.ago, updated_at: 2.years.ago)
      line = invoice.invoice_lines.create!(description: 'work', amount: 10)
      invoice.invoice_lines.create!(description: 'travel', amount: 20)
      Tax.create!(invoice_line_id: line.id, rate: 19)

      # Taxes hang off the lines but are not part of the archiving policy, so
      # they are put in the archive on their own.
      ColdStorage::Archiver.new(Tax, relation: Tax.unscoped.all, force: true).call
      Invoice.archive_now!
    end

    let(:archived_id) { Invoice.archived.first.id }

    it 'leaves the children in the archive by default' do
      expect(Invoice.restore_archived([archived_id])).to eq(1)

      expect(InvoiceLine.count).to eq(0)
      expect(archived_lines.count).to eq(2)
    end

    it 'restores a named relation with the parent' do
      restored = Invoice.restore_archived([archived_id], with: [:invoice_lines])

      expect(restored).to eq(3)
      expect(InvoiceLine.pluck(:description)).to contain_exactly('work', 'travel')
      expect(archived_lines.count).to eq(0)
    end

    it 'accepts a single association name' do
      expect(Invoice.restore_archived([archived_id], with: :invoice_lines)).to eq(3)
      expect(InvoiceLine.count).to eq(2)
    end

    it 'restores the whole graph with :all, grandchildren included' do
      expect(Invoice.restore_archived([archived_id], with: :all)).to eq(4)

      expect(InvoiceLine.count).to eq(2)
      expect(Tax.count).to eq(1)
    end

    it 'restores a nested selection' do
      restored = Invoice.restore_archived([archived_id], with: { invoice_lines: [:taxes] })

      expect(restored).to eq(4)
      expect(Tax.pluck(:rate)).to eq([19])
    end

    it 'restores a has_many :through by name' do
      Invoice.restore_archived([archived_id], with: [:invoice_lines, :taxes])

      expect(Tax.count).to eq(1)
    end

    it 'writes the parent before its children, so foreign keys hold' do
      expect { Invoice.restore_archived([archived_id], with: :all) }.not_to raise_error

      expect(InvoiceLine.first.invoice).to eq(Invoice.unscoped.first)
    end

    it 'restores relations from the archived record too' do
      expect(Invoice.archived.find(archived_id).restore!(with: :all)).to eq(4)
      expect(InvoiceLine.count).to eq(2)
    end

    it 'can keep the archived copies of the children' do
      Invoice.restore_archived([archived_id], with: :all, delete_from_archive: false)

      expect(InvoiceLine.count).to eq(2)
      expect(archived_lines.count).to eq(2)
    end

    it 'rejects an association the model does not have' do
      expect { Invoice.restore_archived([archived_id], with: [:nope]) }
        .to raise_error(ArgumentError, /has no association :nope/)
    end

    it 'points at the owner when asked to restore a belongs_to' do
      expect { ColdStorage.restore(InvoiceLine, [1], with: [:invoice]) }
        .to raise_error(ArgumentError, /restore the owner first/)
    end
  end
end
