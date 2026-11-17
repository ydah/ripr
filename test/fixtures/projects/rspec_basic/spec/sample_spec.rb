# frozen_string_literal: true

require_relative "../lib/sample"

RSpec.describe Sample do
  it "checks adults" do
    expect(Sample.adult?(20)).to be(true)
    expect(Sample.adult?(10)).to be(false)
  end

  it "runs the discount calculation" do
    Sample.discount(100, true)
  end
end
