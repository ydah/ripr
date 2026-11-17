# frozen_string_literal: true

require "ripr/config"
require "tmpdir"

RSpec.describe Ripr::Config do
  it "merges nested CLI settings without discarding file settings" do
    Dir.mktmpdir("ripr-config") do |dir|
      path = File.join(dir, ".ripr.yml")
      File.write(path, "thresholds: {high: 90, low: 70}\ntimeout: {factor: 4, base_ms: 2000}\n")
      config = described_class.load({ thresholds: { "break" => 80 }, timeout: { "factor" => 3 } }, path: path)
      expect(config[:thresholds]).to eq("high" => 90, "low" => 70, "break" => 80)
      expect(config[:timeout]).to eq("factor" => 3, "base_ms" => 2000)
    end
  end

  it "rejects invalid nested settings and non-finite deadlines" do
    expect { described_class.load({ timeout: { "factor" => Float::INFINITY } }) }.to raise_error(ArgumentError)
    expect { described_class.load({ timeout: { "other" => 2 } }) }.to raise_error(ArgumentError)
    expect { described_class.load({ thresholds: { "high" => 3.5 } }) }.to raise_error(ArgumentError)
    expect { described_class.load({ seed: "bad" }) }.to raise_error(ArgumentError)
  end
end
