# frozen_string_literal: true

module Billing
  def self.invoice_total(cents, fee)
    cents + fee
  end

  def self.amount_due(cents, credit)
    cents - credit
  end

  def self.receipt_row_count(quantity)
    (quantity >= 5 ? [:header, :bulk] : [:header, :retail]).length
  end

  def self.estimated_total(cents, tax)
    cents + tax
  end
end
