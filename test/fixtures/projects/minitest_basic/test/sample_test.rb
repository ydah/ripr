# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/sample"

class SampleTest < Minitest::Test
  def test_adult
    assert Sample.adult?(20)
    refute Sample.adult?(10)
  end

  def test_discount_runs
    Sample.discount(100, true)
  end
end
