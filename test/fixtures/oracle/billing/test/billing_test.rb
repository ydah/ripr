# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/billing"

class BillingTest < Minitest::Test
  def test_invoice_without_a_fee
    assert_equal 100, Billing.invoice_total(100, 0)
  end

  def test_invoice_without_credit
    assert_equal 100, Billing.amount_due(100, 0)
  end

  def test_bulk_receipt_row_count
    assert_equal 2, Billing.receipt_row_count(5)
  end

  def test_estimate_includes_tax
    assert_equal 120, Billing.estimated_total(100, 20)
  end
end
