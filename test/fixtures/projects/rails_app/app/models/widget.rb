# frozen_string_literal: true

class Widget < ActiveRecord::Base
  MINIMUM_STOCK = 1

  def stocked?
    stock >= MINIMUM_STOCK
  end
end
