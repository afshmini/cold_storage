# frozen_string_literal: true

RSpec.describe RecordArchiver::SchemaMirror do
  subject(:mirror) { described_class.new(models: [Invoice, Note]) }

  def archive_connection(&block)
    Support::Schema.archive(&block)
  end

  before { Support::Schema.drop_archive! }

  describe '#tables' do
    it 'covers the archivable models and the tables they cascade into' do
      expect(mirror.tables.keys).to contain_exactly('invoices', 'invoice_lines', 'notes')
    end

    it 'defaults to every registered model' do
      expect(described_class.new.tables.keys).to include('invoices', 'notes')
    end
  end

  describe '#plan' do
    it 'reports the tables it would create without touching the archive' do
      changes = mirror.plan

      expect(changes.map(&:type)).to include(:create_table)
      expect(archive_connection { |c| c.table_exists?('invoices') }).to be(false)
    end
  end

  describe '#sync!' do
    before { mirror.sync! }

    it 'creates one table per archivable model' do
      archive_connection do |connection|
        expect(connection.table_exists?('invoices')).to be(true)
        expect(connection.table_exists?('invoice_lines')).to be(true)
        expect(connection.table_exists?('notes')).to be(true)
      end
    end

    it 'copies every column with its type' do
      source = ActiveRecord::Base.connection_pool.with_connection { |c| c.columns('invoices') }
      target = archive_connection { |c| c.columns('invoices') }

      expect(target.map(&:name)).to include(*source.map(&:name))
      expect(target.index_by(&:name).slice(*source.map(&:name)).transform_values(&:sql_type))
        .to eq(source.index_by(&:name).transform_values(&:sql_type))
    end

    it 'keeps array columns arrays' do
      column = archive_connection { |c| c.columns('invoices').find { |col| col.name == 'tags' } }

      expect(column.array?).to be(true)
    end

    it 'creates the enum types the columns depend on' do
      names = archive_connection { |c| c.enum_types.to_h.keys }

      expect(names).to include('invoice_state')
    end

    it 'adds the archived_at stamp column' do
      expect(archive_connection { |c| c.column_exists?('invoices', :archived_at) }).to be(true)
    end

    it 'keeps the primary key so re-archiving a row cannot duplicate it' do
      expect(archive_connection { |c| c.primary_key('invoices') }).to eq('id')
    end

    it 'mirrors indexes' do
      names = archive_connection { |c| c.indexes('invoices').map(&:name) }

      expect(names).to include('index_invoices_on_number', 'index_invoices_on_deleted_at')
    end

    it 'mirrors a unique index as a plain one, so history can repeat itself' do
      index = archive_connection { |c| c.indexes('invoices').find { |i| i.name == 'index_invoices_on_number' } }

      expect(index.unique).to be(false)
      expect(ActiveRecord::Base.connection_pool.with_connection do |c|
        c.indexes('invoices').find { |i| i.name == 'index_invoices_on_number' }.unique
      end).to be(true)
    end

    it 'does not copy foreign keys' do
      expect(archive_connection { |c| c.foreign_keys('invoice_lines') }).to be_empty
    end

    it 'drops NOT NULL, so a schema that gets stricter later cannot reject old rows' do
      column = archive_connection { |c| c.columns('invoice_lines').find { |col| col.name == 'invoice_id' } }

      expect(column.null).to be(true)
    end

    it 'creates its own bookkeeping tables' do
      archive_connection do |connection|
        expect(connection.table_exists?('record_archiver_runs')).to be(true)
        expect(connection.table_exists?('record_archiver_metadata')).to be(true)
      end
    end

    it 'is idempotent' do
      expect(mirror.sync!).to be_empty
      expect(described_class.new(models: [Invoice, Note]).plan).to be_empty
    end
  end

  describe 'following migrations' do
    before { mirror.sync! }

    after do
      Support::Schema.source do |connection|
        connection.remove_column('invoices', :reference) if connection.column_exists?('invoices', :reference)
        connection.remove_index('invoices', name: 'index_invoices_on_reference', if_exists: true)
      end
      Invoice.reset_column_information
    end

    it 'detects a column added by a migration' do
      Support::Schema.source { |c| c.add_column('invoices', :reference, :string) }

      changes = described_class.new(models: [Invoice]).plan

      expect(changes.map { |change| [change.type, change.name] }).to include([:add_column, 'reference'])
    end

    it 'applies the new column to the archive' do
      Support::Schema.source { |c| c.add_column('invoices', :reference, :string) }
      described_class.new(models: [Invoice]).sync!

      expect(archive_connection { |c| c.column_exists?('invoices', :reference) }).to be(true)
    end

    it 'applies an index added by a migration' do
      Support::Schema.source do |c|
        c.add_column('invoices', :reference, :string)
        c.add_index('invoices', :reference, name: 'index_invoices_on_reference')
      end
      described_class.new(models: [Invoice]).sync!

      expect(archive_connection { |c| c.indexes('invoices').map(&:name) }).to include('index_invoices_on_reference')
    end

    it 'keeps archived columns that the primary database dropped' do
      Support::Schema.source { |c| c.add_column('invoices', :reference, :string) }
      described_class.new(models: [Invoice]).sync!
      Support::Schema.source { |c| c.remove_column('invoices', :reference) }

      changes = described_class.new(models: [Invoice]).sync!

      expect(changes.map(&:type)).to eq([:extra_column])
      expect(archive_connection { |c| c.column_exists?('invoices', :reference) }).to be(true)
    end

    it 'drops them when drop_removed_columns is on' do
      Support::Schema.source { |c| c.add_column('invoices', :reference, :string) }
      described_class.new(models: [Invoice]).sync!
      Support::Schema.source { |c| c.remove_column('invoices', :reference) }

      RecordArchiver.config.drop_removed_columns = true
      described_class.new(models: [Invoice]).sync!

      expect(archive_connection { |c| c.column_exists?('invoices', :reference) }).to be(false)
    end
  end
end
