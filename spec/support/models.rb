# frozen_string_literal: true

ActiveRecord::Base.extend(RecordArchiver::Model)

module Support
  # Base class of the spec models.
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end
end

# Soft-deletable, cascades into its lines.
class Invoice < Support::Record
  self.table_name = 'invoices'

  has_many :invoice_lines, dependent: :destroy
  has_many :taxes, through: :invoice_lines

  default_scope { where(deleted_at: nil) }

  archivable after: 12.months, every: 1.month, cascade: [:invoice_lines]
end

class InvoiceLine < Support::Record
  self.table_name = 'invoice_lines'

  belongs_to :invoice
  has_many :taxes, dependent: :destroy
end

class Tax < Support::Record
  self.table_name = 'taxes'

  belongs_to :invoice_line, optional: true
end

# Archives soft-deleted rows only.
class Note < Support::Record
  self.table_name = 'notes'

  archivable deleted: true
end

# Keeps hard deletes: nothing is swept on a schedule, rows are captured as they
# are destroyed.
class Receipt < Support::Record
  self.table_name = 'receipts'

  archivable on_destroy: true
end
