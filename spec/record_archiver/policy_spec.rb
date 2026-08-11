# frozen_string_literal: true

RSpec.describe RecordArchiver::Policy do
  describe 'option validation' do
    it 'rejects unknown options' do
      expect { described_class.new(Note, afterr: 1.day) }
        .to raise_error(RecordArchiver::InvalidPolicyError, /unknown archivable option/)
    end

    it 'refuses a policy without any criterion' do
      expect { described_class.new(Note, every: 1.month) }
        .to raise_error(RecordArchiver::InvalidPolicyError, /at least one of/)
    end

    it 'rejects a non duration' do
      expect { described_class.new(Note, after: 'a while') }
        .to raise_error(RecordArchiver::InvalidPolicyError, /duration/)
    end

    it 'accepts older_than: as an alias of after:' do
      expect(described_class.new(Note, older_than: 3.months).after).to eq(3.months)
    end

    it 'reports an unknown column against the real table' do
      policy = described_class.new(Note, after: 1.day, on: :closed_at)

      expect { policy.validate_against_schema!(Note) }
        .to raise_error(RecordArchiver::InvalidPolicyError, /has no column :closed_at/)
    end
  end

  describe 'defaults' do
    it 'measures age on created_at' do
      expect(described_class.new(Note, after: 1.day).on).to eq(:created_at)
    end

    it 'measures age on the deleted column when archiving deleted rows' do
      policy = described_class.new(Note, deleted: true, after: 1.day)

      expect(policy.on).to eq(:deleted_at)
      expect(policy.deleted?).to be(true)
    end
  end

  describe '#relation' do
    before do
      # unscoped: insert_all would otherwise force the default scope's
      # deleted_at: nil onto every row.
      Invoice.unscoped.insert_all!(
        [
          { number: 'old',     created_at: 2.years.ago, updated_at: 2.years.ago, deleted_at: nil },
          { number: 'recent',  created_at: 1.month.ago, updated_at: 1.month.ago, deleted_at: nil },
          { number: 'deleted', created_at: 2.years.ago, updated_at: 2.years.ago, deleted_at: 1.day.ago }
        ]
      )
    end

    it 'selects rows older than the retention window' do
      policy = described_class.new(Invoice, after: 12.months)

      expect(policy.relation(Invoice).pluck(:number)).to contain_exactly('old', 'deleted')
    end

    it 'ignores the default scope, so soft-deleted rows are archivable too' do
      expect(Invoice.count).to eq(2) # default_scope hides the deleted one
      expect(described_class.new(Invoice, after: 12.months).relation(Invoice).count).to eq(2)
    end

    it 'selects only soft-deleted rows with deleted: true' do
      policy = described_class.new(Invoice, deleted: true)

      expect(policy.relation(Invoice).pluck(:number)).to eq(['deleted'])
    end

    it 'combines deleted: with an age' do
      policy = described_class.new(Invoice, deleted: true, after: 1.year)

      expect(policy.relation(Invoice).count).to eq(0)
    end

    it 'narrows through scope:' do
      policy = described_class.new(Invoice, after: 12.months, scope: -> { where(number: 'old') })

      expect(policy.relation(Invoice).pluck(:number)).to eq(['old'])
    end
  end

  describe '#due?' do
    it 'is always due without every:' do
      expect(described_class.new(Note, deleted: true).due?(Time.current)).to be(true)
    end

    it 'is due when it never ran' do
      expect(described_class.new(Note, deleted: true, every: 1.month).due?(nil)).to be(true)
    end

    it 'is not due inside the window' do
      policy = described_class.new(Note, deleted: true, every: 1.month)

      expect(policy.due?(2.days.ago)).to be(false)
      expect(policy.due?(40.days.ago)).to be(true)
    end
  end
end
