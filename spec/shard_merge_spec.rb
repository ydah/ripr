# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"
require "ripr/engine/shard_merge"

RSpec.describe Ripr::Engine::ShardMerge do
  let(:digest) { Digest::SHA256.hexdigest("plan") }
  let(:test_id) { "SampleTest#test_boundary" }
  let(:test) { { "file" => "test/sample_test.rb", "line" => 11, "duration_ms" => 3.2 } }

  def mutation(ast_path, status: "not_detected")
    site = "lib/sample.rb::Sample#boundary::#{ast_path}::comparison"
    full_id = "#{site}::>"
    location = { "file" => "lib/sample.rb", "line" => 4, "column" => 5, "end_line" => 4, "end_column" => 11 }
    { "id" => Digest::SHA256.hexdigest(full_id)[0, 10], "full_id" => full_id, "site" => site, "subject" => "Sample#boundary",
      "method_hash" => Digest::SHA256.hexdigest("method"), "operator" => "comparison", "original" => "x >= 4", "mutated" => "x > 4",
      "replacement" => ">", "mode" => "value", "status" => status, "location" => location,
      "covering_tests" => [test.merge("id" => test_id)], "observed" => [[4, 4]], "load_reached" => false }
  end

  def plan(*buckets)
    records = buckets.flatten(1)
    sites = records.map { |record| record.fetch("site") }
    reach = sites.to_h { |site| [site, [test_id]] }
    samples = sites.to_h { |site| [site, [[4, 4]]] }
    probe = { "reach" => reach, "samples" => samples, "load_reached" => [] }
    { "version" => 1, "shards" => buckets.map { |bucket| bucket.map { |record| record.fetch("full_id") } },
      "identity" => { "sources" => { "lib/sample.rb" => Digest::SHA256.hexdigest("source") },
                      "mutation_fingerprints" => records.to_h { |record| [record.fetch("full_id"), fingerprint(record)] } },
      "baseline" => { "tests" => { test_id => test }, "probe" => probe } }
  end

  def fingerprint(record)
    Ripr::Engine::ShardPlan.mutation_fingerprint(record)
  end

  def write_artifact(directory, index, total, records, name: "shard-#{index}.json", **overrides)
    document = { "version" => 1, "plan_digest" => digest, "index" => index, "total" => total, "results" => records }
    path = File.join(directory, name)
    File.write(path, JSON.generate(document.merge(overrides.transform_keys(&:to_s))))
    path
  end

  it "returns all results in full ID order regardless of artifact order, including an empty shard" do
    first = mutation("a")
    second = mutation("b", status: "killed").merge("killed_by" => test_id)
    manifest = plan([second], [], [first])
    Dir.mktmpdir do |directory|
      paths = [write_artifact(directory, 3, 3, [first]), write_artifact(directory, 1, 3, [second]),
               write_artifact(directory, 2, 3, [])]

      expect(described_class.call(manifest, digest, paths)).to eq([first, second])
    end
  end

  it "requires a result artifact for every shard, including an empty shard" do
    first = mutation("a")
    Dir.mktmpdir do |directory|
      path = write_artifact(directory, 1, 2, [first])

      expect { described_class.call(plan([first], []), digest, [path]) }
        .to raise_error(ArgumentError, /missing shard results for 2/i)
    end
  end

  it "rejects duplicated shard indices without changing the inputs" do
    first = mutation("a")
    Dir.mktmpdir do |directory|
      paths = [write_artifact(directory, 1, 2, [first]), write_artifact(directory, 1, 2, [first], name: "retry.json")]
      bytes = paths.map { |path| File.binread(path) }

      expect { described_class.call(plan([first], []), digest, paths) }.to raise_error(ArgumentError, /duplicate shard result for 1/i)
      expect(paths.map { |path| File.binread(path) }).to eq(bytes)
    end
  end

  it "rejects a valid mutation assigned to a different shard" do
    first = mutation("a")
    second = mutation("b")
    Dir.mktmpdir do |directory|
      paths = [write_artifact(directory, 1, 2, [second]), write_artifact(directory, 2, 2, [first])]

      expect { described_class.call(plan([first], [second]), digest, paths) }
        .to raise_error(ArgumentError, /shard 1.*assigned mutations/i)
    end
  end

  it "rejects a result from a different plan" do
    first = mutation("a")
    Dir.mktmpdir do |directory|
      path = write_artifact(directory, 1, 1, [first], plan_digest: Digest::SHA256.hexdigest("different plan"))

      expect { described_class.call(plan([first]), digest, [path]) }.to raise_error(ArgumentError, /different shard plan/i)
    end
  end

  it "rejects malformed result JSON, including a non-object document" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "shard.json")

      ["{", "[]"].each do |contents|
        File.write(path, contents)
        expect { described_class.call(plan([]), digest, [path]) }.to raise_error(ArgumentError, /invalid shard result/i)
      end
    end
  end

  it "rejects an unsupported result version, invalid shard index, or mismatched total" do
    Dir.mktmpdir do |directory|
      [write_artifact(directory, 0, 1, []), write_artifact(directory, 1, 2, []),
       write_artifact(directory, 1, 1, [], name: "unsupported.json", version: 2)].each do |path|
        expect { described_class.call(plan([]), digest, [path]) }.to raise_error(ArgumentError, /invalid shard result/i)
      end
    end
  end

  it "rejects duplicated, malformed, or unavailable mutation records" do
    first = mutation("a")
    manifest = plan([first])
    records = [[first, first], [nil], [first.merge("status" => "planned")], [first.merge("status" => "bogus")],
               [first.merge("location" => first.fetch("location").merge("file" => "../unplanned.rb"))],
               [first.merge("location" => first.fetch("location").merge("line" => 3))],
               [first.merge("covering_tests" => [test.merge("id" => "other")])], [first.merge("observed" => [[5, 4]])],
               [first.merge("status" => "not_revealed")]]

    Dir.mktmpdir do |directory|
      records.each do |results|
        path = write_artifact(directory, 1, 1, results)
        expect { described_class.call(manifest, digest, [path]) }.to raise_error(ArgumentError, /invalid shard result|assigned mutations/i)
      end
    end
  end
end
