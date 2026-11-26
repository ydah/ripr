# frozen_string_literal: true

require "ripr/engine/baseline_cache"

RSpec.describe Ripr::Engine::BaselineCache do
  let(:tests) do
    [{ "id" => "a", "file" => "spec/a_spec.rb", "line" => 3, "duration_ms" => 0 },
     { "id" => "b", "file" => "spec/b_spec.rb", "line" => 5, "duration_ms" => 2 }]
  end
  let(:hashes) { { "spec/a_spec.rb" => "a1", "spec/b_spec.rb" => "b1" } }
  let(:previous) do
    { "success" => true, "env_hash" => "environment", "source_hash" => "source", "test_hashes" => hashes,
      "tests" => tests.to_h { |test| [test.fetch("id"), test] },
      "probe" => { "reach" => { "a" => ["a"], "shared" => %w[a b], "b" => ["b"] },
                   "infect" => { "mutant" => %w[a b] },
                   "samples" => { "a" => [[true, false], [nil, 0], ["x", 2]], "shared" => [[1, 2]], "b" => [[3, 4]] },
                   "load_reached" => [] } }
  end

  def cache(snapshot = previous, **options)
    described_class.new(snapshot, env_hash: "environment", source_hash: "source", test_hashes: hashes, tests: tests, **options)
  end

  it "reuses valid zero-duration tests and all three scalar observation samples" do
    baseline = cache

    expect(baseline.test_ids).to eq([])
    expect(baseline.reused_count).to eq(2)
    expect(baseline.combine(nil)).to eq(previous.merge("failures" => []))
  end

  it "prunes changed tests and their samples while combining fresh reach and infection evidence" do
    changed_hashes = hashes.merge("spec/b_spec.rb" => "b2")
    baseline = cache(test_hashes: changed_hashes)
    updated = tests.last.merge("duration_ms" => 7)
    fresh = { "tests" => { "b" => updated },
              "probe" => { "reach" => { "a" => ["b"] }, "infect" => { "mutant" => ["b"] },
                           "samples" => { "a" => [[false, true], [true, false]] }, "load_reached" => ["fresh"] } }

    expect(baseline.test_ids).to eq(["b"])
    expect(baseline.reused_count).to eq(1)
    expect(baseline.combine(fresh, load_reached: ["current"])).to eq(
      "success" => true, "failures" => [], "tests" => { "a" => tests.first, "b" => updated },
      "probe" => { "reach" => { "a" => %w[a b], "shared" => ["a"] }, "infect" => { "mutant" => %w[a b] },
                   "samples" => { "a" => [[true, false], [nil, 0], ["x", 2]] }, "load_reached" => %w[fresh current] },
      "env_hash" => "environment", "source_hash" => "source", "test_hashes" => changed_hashes
    )
  end

  it "requires a complete baseline when changed tests shared load-time observations" do
    previous.fetch("probe")["load_reached"] = ["loaded"]

    expect(cache.combine(nil, load_reached: %w[loaded current]).dig("probe", "load_reached")).to eq(%w[loaded current])
    baseline = cache(test_hashes: hashes.merge("spec/b_spec.rb" => "b2"))
    expect(baseline.test_ids).to be_nil
    expect(baseline.reused_count).to eq(0)
    expect(baseline.combine(nil).fetch("tests")).to eq({})
  end

  it "requires a complete baseline when an observation contains more than three samples" do
    previous.fetch("probe").fetch("samples").fetch("a") << [4, 5]

    expect(cache.test_ids).to be_nil
    expect(cache.reused_count).to eq(0)
  end

  it "requires a complete baseline when cached load observations have invalid shapes" do
    [nil, {}, [1]].each do |load_reached|
      previous.fetch("probe")["load_reached"] = load_reached

      expect(cache.test_ids).to be_nil
      expect(cache.reused_count).to eq(0)
    end
  end
end
