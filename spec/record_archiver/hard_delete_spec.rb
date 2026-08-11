# frozen_string_literal: true

RSpec.describe 'archivable on_destroy' do
  before(:all) { RecordArchiver.sync_schema!(models: [Receipt, Invoice]) }

  let(:archived) { RecordArchiver::ArchiveModel.for(Receipt) }

  describe 'a hard delete' do
    let!(:receipt) { Receipt.create!(reference: 'R-1') }

    it 'keeps a copy of the row that is about to disappear' do
      receipt.destroy!

      expect(Receipt.count).to eq(0)
      expect(archived.pluck(:id, :reference)).to eq([[receipt.id, 'R-1']])
    end

    it 'stamps archived_at' do
      receipt.destroy!

      expect(archived.first.archived_at).to be_within(1.minute).of(Time.current)
    end

    it 'covers destroy_all' do
      Receipt.create!(reference: 'R-2')

      Receipt.destroy_all

      expect(Receipt.count).to eq(0)
      expect(archived.pluck(:reference)).to contain_exactly('R-1', 'R-2')
    end

    it 'does not double up when the row was archived before' do
      receipt.destroy!
      Receipt.insert_all!([{ id: receipt.id, reference: 'R-1', created_at: Time.current,
                             updated_at: Time.current }])
      Receipt.find(receipt.id).destroy!

      expect(archived.count).to eq(1)
    end

    it 'cannot see delete_all, which never runs callbacks' do
      Receipt.delete_all

      expect(archived.count).to eq(0)
    end
  end

  describe 'a scheduled run' do
    before { Receipt.create!(reference: 'R-1') }

    it 'sweeps nothing: on_destroy only reacts to deletes' do
      expect(Receipt.archivable_records).to be_empty
      expect(Receipt.archivable_count).to eq(0)
    end

    it 'skips the model instead of archiving the whole table' do
      result = RecordArchiver.archive(Receipt)

      expect(result).to be_skipped
      expect(result.reason).to eq(:destroy_only)
      expect(Receipt.count).to eq(1)
    end
  end

  describe 'when the archive cannot be reached' do
    let!(:receipt) { Receipt.create!(reference: 'R-1') }

    before { Support::Schema.archive { |connection| connection.drop_table('receipts', force: :cascade) } }

    after { RecordArchiver.sync_schema!(models: [Receipt]) }

    it 'blocks the delete rather than losing the row' do
      expect { receipt.destroy! }.to raise_error(RecordArchiver::SchemaMissingError)
      expect(Receipt.count).to eq(1)
    end

    it 'lets the delete through when configured to only log' do
      RecordArchiver.config.on_destroy_error = :log

      expect { receipt.destroy! }.not_to raise_error
      expect(Receipt.count).to eq(0)
    end
  end

  describe 'combined with a retention rule' do
    around do |example|
      Note.archivable deleted: true, on_destroy: true
      example.run
    ensure
      Note.archivable deleted: true
    end

    it 'still sweeps on the schedule' do
      Note.create!(body: 'soft', deleted_at: 1.hour.ago)

      Note.archive_now!

      expect(Note.archived.pluck(:body)).to eq(['soft'])
    end

    it 'also catches a destroy' do
      Note.create!(body: 'hard').destroy!

      expect(Note.archived.pluck(:body)).to eq(['hard'])
    end

    it 'stops catching destroys once the option is taken away' do
      Note.archivable deleted: true

      Note.create!(body: 'hard').destroy!

      expect(Note.archived.count).to eq(0)
    end
  end
end
