# frozen_string_literal: true

module Sample
  def self.adult?(age)
    age >= 18
  end

  def self.discount(price, member)
    member ? price * 0.9 : price
  end

  def self.unused(x)
    x + 1
  end
end
