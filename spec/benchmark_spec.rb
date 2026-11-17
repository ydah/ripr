# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

RSpec.describe "benchmark script" do
  it "measures five successful nonempty runs in each mode" do
    root = File.expand_path("..", __dir__)
    output, error, status = Open3.capture3(
      RbConfig.ruby, File.join(root, "script/benchmark.rb"), "minitest", "test/*_test.rb",
      chdir: File.join(root, "test/fixtures/projects/minitest_basic")
    )
    expect(status.success?).to be(true), error
    result = JSON.parse(output)
    expect(result.fetch("modes").keys).to eq(%w[plain instrumented probe])
    result.fetch("modes").each_value do |mode|
      expect(mode.fetch("samples_ms").size).to eq(5)
      expect(mode.fetch("tests")).to eq(2)
      expect(mode.fetch("median_ms")).to be_positive
    end
    expect(result.fetch("mutants")).to be_positive
    expect(result.fetch("skipped_fraction")).to be_positive
  end
end
