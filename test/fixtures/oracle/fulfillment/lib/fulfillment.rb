# frozen_string_literal: true

module Fulfillment
  def self.customs_form?(weight)
    weight >= 2
  end

  def self.free_shipping?(subtotal)
    subtotal >= 50
  end

  def self.can_pick_up?(minutes)
    minutes <= 15
  end

  def self.quote(weight)
    { currency: :usd, oversize: weight >= 20 }
  end

  def self.signature_required?(value)
    value >= 100
  end
end
