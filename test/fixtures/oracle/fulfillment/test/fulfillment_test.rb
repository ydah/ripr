# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/fulfillment"

class FulfillmentTest < Minitest::Test
  def test_shipping_subtotals
    assert Fulfillment.free_shipping?(75)
    refute Fulfillment.free_shipping?(20)
  end

  def test_pickup_windows
    assert Fulfillment.can_pick_up?(10)
    refute Fulfillment.can_pick_up?(16)
  end

  def test_quote_currency
    assert_equal :usd, Fulfillment.quote(20).fetch(:currency)
  end

  def test_signature_value_boundary
    assert Fulfillment.signature_required?(100)
  end
end
