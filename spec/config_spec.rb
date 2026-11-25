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

  it "limits automatic jobs to the smaller of the CPU and memory limits" do
    allow(Etc).to receive(:nprocessors).and_return(8)
    default = described_class.load({}, path: File::NULL)
    automatic = described_class.load({ jobs: "auto" }, path: File::NULL)

    expect(default.with_worker_limit { 3 }[:jobs]).to eq(3)
    expect(automatic.with_worker_limit { 9 }[:jobs]).to eq(8)
    expect(automatic.with_worker_limit { nil }[:jobs]).to eq(8)
  end

  it "keeps an explicit job count without querying the worker limit" do
    config = described_class.load({ jobs: 4 }, path: File::NULL)

    expect(config.with_worker_limit { raise "unexpected worker limit query" }[:jobs]).to eq(4)
  end

  it "uses isolated Rails boot for an explicit boot file in a conventional Rails project" do
    Dir.mktmpdir("ripr-rails-config") do |dir|
      Dir.chdir(dir) do
        Dir.mkdir("config")
        File.write("config/application.rb", "")
        File.write("config/environment.rb", "")
        config = described_class.load({ boot: "config/environment.rb" })
        expect(config[:rails]).to be(true)
        expect(config[:include]).to include("app/**/*.rb")
      end
    end
  end
end
