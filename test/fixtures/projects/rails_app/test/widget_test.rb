# frozen_string_literal: true

require_relative "../config/environment"
require "rails/test_help"

class WidgetTest < ActiveSupport::TestCase
  def test_stocked
    assert Widget.find_by!(label: "booted").stocked?
    assert Widget.new(stock: 1).stocked?
    refute Widget.new(stock: 0).stocked?
  end
end
