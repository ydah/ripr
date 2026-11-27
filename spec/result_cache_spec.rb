# frozen_string_literal: true

require "tmpdir"
require "prism"
require "ripr/config"
require "ripr/engine/result_cache"

RSpec.describe Ripr::Engine::ResultCache do
  let(:test) { { "id" => "BoundaryTest#test_adult", "file" => "boundary_test.rb", "line" => 3 } }
  let(:site) { "sample.rb::Sample#adult?::body::comparison" }
  let(:mutant) do
    { "id" => "boundary", "full_id" => "#{site}::>", "site" => site, "method_hash" => "adult-method" }
  end
  let(:result) do
    mutant.merge("status" => "killed", "killed_by" => test.fetch("id"), "covering_tests" => [test], "observed" => [[18, 18]])
  end
  let(:baseline) { { "tests" => { test.fetch("id") => test } } }

  around do |example|
    Dir.mktmpdir("ripr-result-cache") do |directory|
      Dir.chdir(directory) do
        File.write(test.fetch("file"), "class BoundaryTest; def test_adult; end; end\n")
        example.run
      end
    end
  end

  def cache(overrides = {}, method_hashes: { mutant.fetch("full_id") => mutant.fetch("method_hash") })
    config = Ripr::Config.load(overrides)
    described_class.new(config, sources: { "sample.rb" => "def adult?(age); age >= 18; end" },
                                test_files: [test.fetch("file")], framework: "minitest", method_hashes: method_hashes,
                                test_ids: [test.fetch("id")], probe_sites: [site])
  end

  def edit_snapshot
    snapshot = Ripr::Snapshot.new
    data = snapshot.read
    yield data
    snapshot.write(data)
  end

  it "keeps valid results from a previous partial run and writes covering test fingerprints" do
    second = result.merge("id" => "second", "full_id" => "#{site}::<", "status" => "not_infected")
    hashes = [mutant, second].to_h { |record| record.values_at("full_id", "method_hash") }
    cache({}, method_hashes: hashes).write([result, second], baseline, {})
    cache({}, method_hashes: hashes).write([second.merge("status" => "killed")], baseline, { "reused" => 1 })

    snapshot = Ripr::Snapshot.new.read
    expect(snapshot.fetch("mutants").keys).to contain_exactly(mutant.fetch("full_id"), second.fetch("full_id"))
    expect(cache({}, method_hashes: hashes).result_for(mutant)).to include(result.merge("reused" => true))
    stored = snapshot.fetch("mutants").fetch(second.fetch("full_id"))
    expect(stored.fetch("status")).to eq("killed")
    expect(stored.fetch("tests")).to eq(test.fetch("file") => Digest::SHA256.file(test.fetch("file")).hexdigest)
    expect(Time.iso8601(stored.fetch("recorded_at")).utc?).to be(true)
    expect(snapshot.fetch("source_hash")).to eq(cache.source_hash)
    expect(snapshot.fetch("metrics")).to eq("reused" => 1)
  end

  it "drops previous records whose method, environment, or evidence is no longer valid" do
    cache.write([result], baseline, {})
    original = Ripr::Snapshot.new.read
    changes = [
      { "method_hash" => "different-method" }, { "env_hash" => "different-environment" }, { "observed" => [1] }
    ]
    changes.each do |damage|
      Ripr::Snapshot.new.write(original)
      edit_snapshot { |data| data.fetch("mutants").fetch(mutant.fetch("full_id")).merge!(damage) }
      cache.write([], baseline, {})
      expect(Ripr::Snapshot.new.read.fetch("mutants")).to be_empty
    end
    Ripr::Snapshot.new.write(original)
    cache({}, method_hashes: {}).write([], baseline, {})
    expect(Ripr::Snapshot.new.read.fetch("mutants")).to be_empty
  end

  { verify_not_infected: "not_infected", verify_killed: "killed" }.each do |option, status|
    it "reruns #{status} records when #{option} is requested" do
      cache({ option => true }).write([result.merge("status" => status)], baseline, {})
      expect(cache({ option => true }).result_for(mutant)).to be_nil

      other_status = status == "killed" ? "not_infected" : "killed"
      cache({ option => true }).write([result.merge("status" => other_status)], baseline, {})
      expect(cache({ option => true }).result_for(mutant)).to include("status" => other_status, "reused" => true)
    end
  end

  it "reuses the maximum three observation pairs and rejects an oversized sample" do
    samples = [[true, false], [nil, "boundary"], [18, 18.5]]
    cache.write([result.merge("observed" => samples)], baseline, {})
    expect(cache.result_for(mutant)).to include("observed" => samples, "reused" => true)

    edit_snapshot { |data| data.fetch("mutants").fetch(mutant.fetch("full_id"))["observed"] << [19, 18] }
    expect(cache.result_for(mutant)).to be_nil
  end

  it "requires a valid propagation example before reusing not_revealed" do
    propagation = { "test_id" => test.fetch("id"), "call" => 1,
                    "original" => ["return", ["TrueClass", true]], "mutant" => ["return", ["FalseClass", false]] }
    cache.write([result.merge("status" => "not_revealed", "propagation" => propagation)], baseline, {})
    expect(cache.result_for(mutant)).to include("status" => "not_revealed", "propagation" => propagation)

    edit_snapshot { |data| data.fetch("mutants").fetch(mutant.fetch("full_id")).fetch("propagation")["call"] = 0 }
    expect(cache.result_for(mutant)).to be_nil
  end

  it "uses kill history only while the killing test and its fingerprint still match" do
    cache.write([result], baseline, {})
    original = Ripr::Snapshot.new.read
    tests = baseline.fetch("tests")
    expect(cache.previous_killer(mutant, tests.keys, tests)).to eq(test.fetch("id"))

    damages = [
      ->(data) { data["baseline"] = nil },
      ->(data) { data["test_hashes"] = nil },
      ->(data) { data.fetch("baseline").fetch("tests")[test.fetch("id")] = nil },
      ->(data) { data.fetch("baseline").fetch("tests").fetch(test.fetch("id"))["line"] = 9 },
      ->(data) { data.fetch("test_hashes")[test.fetch("file")] = "old-fingerprint" },
      ->(data) { data.fetch("mutants").fetch(mutant.fetch("full_id"))["status"] = "not_detected" },
      ->(data) { data.fetch("mutants").fetch(mutant.fetch("full_id"))["full_id"] = "#{site}::<" },
      ->(data) { data.fetch("mutants").fetch(mutant.fetch("full_id")).fetch("tests")[test.fetch("file")] = "old-fingerprint" }
    ]
    damages.each do |damage|
      copy = JSON.parse(JSON.generate(original))
      damage.call(copy)
      Ripr::Snapshot.new.write(copy)
      expect(cache.previous_killer(mutant, tests.keys, tests)).to be_nil
    end
    Ripr::Snapshot.new.write(original)
    expect(cache.previous_killer(mutant, [], tests)).to be_nil
    expect(cache.previous_killer(mutant, tests.keys, {})).to be_nil
  end
end
