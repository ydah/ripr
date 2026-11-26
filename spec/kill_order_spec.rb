# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "historical mutation test ordering" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }
  let(:fast) { "FastTest#test_count" }
  let(:slow) { "SlowTest#test_count" }

  def run_mutations(directory, *arguments)
    output, error, status = Open3.capture3(RbConfig.ruby, executable, "--operators", "integer_literal",
                                           "--reporter", "agent", "--jobs", "1", *arguments, chdir: directory)
    expect(status).to be_success, error
    JSON.parse(output)
  end

  def with_history
    Dir.mktmpdir("ripr-kill-order") do |directory|
      FileUtils.mkdir_p(File.join(directory, "lib"))
      FileUtils.mkdir_p(File.join(directory, "test"))
      File.write(File.join(directory, "lib/sample.rb"), "module Sample; def self.count = 10; end\n")
      File.write(File.join(directory, "test/fast_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class FastTest < Minitest::Test
          def test_count
            File.open("mutation-order", "a") { |file| file.puts "fast" } if File.exist?("record-order")
            assert_includes [0, 10], Sample.count
          end
        end
      RUBY
      File.write(File.join(directory, "test/slow_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SlowTest < Minitest::Test
          def test_count
            sleep 0.1
            File.open("mutation-order", "a") { |file| file.puts "slow" } if File.exist?("record-order")
            assert_equal 10, Sample.count
          end
        end
      RUBY
      run_mutations(directory)
      path = File.join(directory, ".ripr/snapshot.json")
      snapshot = JSON.parse(File.read(path))
      mutants = snapshot.fetch("mutants").values
      zero = mutants.find { |record| record["replacement"] == "0" }
      upper = mutants.find { |record| record["replacement"] == "11" }
      expect(zero.fetch("killed_by")).to eq(slow)
      expect(upper.fetch("killed_by")).to eq(fast)
      yield directory, path, snapshot, zero, upper
    end
  end

  it "runs the mutant's previous killing test first even when another test is faster" do
    with_history do |directory, path, snapshot, _zero, mutant|
      tests = snapshot.fetch("baseline").fetch("tests")
      tests.fetch(fast)["duration_ms"] = 100
      tests.fetch(slow)["duration_ms"] = 1
      File.write(path, JSON.generate(snapshot))
      File.write(File.join(directory, "record-order"), "")

      result = run_mutations(directory, "--only", mutant.fetch("id"))
      expect(result.fetch("summary").fetch("killed")).to eq(1)
      expect(result.dig("run", "metrics", "baseline_tests_run")).to eq(0)
      expect(File.readlines(File.join(directory, "mutation-order"), chomp: true)).to eq(["fast"])
      expect(JSON.parse(File.read(path)).dig("mutants", mutant.fetch("full_id"), "killed_by")).to eq(fast)
    end
  end

  it "falls back to the last killing test from another variant at the same site" do
    with_history do |directory, path, snapshot, zero, upper|
      mutant = snapshot.fetch("mutants").values.find { |record| record["replacement"] == "9" }
      zero["recorded_at"] = "2026-11-25T00:01:00Z"
      upper["recorded_at"] = "2026-11-25T00:00:00Z"
      snapshot["mutants"] = { zero.fetch("full_id") => zero, upper.fetch("full_id") => upper }
      tests = snapshot.fetch("baseline").fetch("tests")
      tests.fetch(fast)["duration_ms"] = 1
      tests.fetch(slow)["duration_ms"] = 100
      File.write(path, JSON.generate(snapshot))
      File.write(File.join(directory, "record-order"), "")

      run_mutations(directory, "--only", mutant.fetch("id"))
      expect(File.readlines(File.join(directory, "mutation-order"), chomp: true)).to eq(["slow"])
      expect(JSON.parse(File.read(path)).dig("mutants", mutant.fetch("full_id"), "killed_by")).to eq(slow)
    end
  end

  it "ignores history for a killing test whose file changed" do
    with_history do |directory, path, snapshot, zero, mutant|
      snapshot["mutants"] = { zero.fetch("full_id") => zero }
      File.write(path, JSON.generate(snapshot))
      File.open(File.join(directory, "test/slow_test.rb"), "a") { |file| file.puts "# Change the file fingerprint." }

      run_mutations(directory, "--only", mutant.fetch("id"))
      expect(JSON.parse(File.read(path)).dig("mutants", mutant.fetch("full_id"), "killed_by")).to eq(fast)
    end
  end

  it "ignores malformed kill records and orders tests with equal durations by ID" do
    with_history do |directory, path, snapshot, zero, mutant|
      zero["covering_tests"] = [1]
      snapshot["mutants"] = { zero.fetch("full_id") => zero }
      baseline = snapshot.fetch("baseline")
      baseline.fetch("tests").each_value { |test| test["duration_ms"] = 1 }
      baseline.dig("probe", "reach").fetch(mutant.fetch("site")).reverse!
      File.write(path, JSON.generate(snapshot))
      File.write(File.join(directory, "record-order"), "")

      run_mutations(directory, "--only", mutant.fetch("id"))
      expect(File.readlines(File.join(directory, "mutation-order"), chomp: true)).to eq(["fast"])
    end
  end
end

RSpec.describe "verification of probe verdicts" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }

  it "keeps verified non-infection and reports a discrepancy when replay kills a mutant" do
    Dir.mktmpdir("ripr-verify-probe") do |directory|
      FileUtils.mkdir_p(File.join(directory, "lib"))
      FileUtils.mkdir_p(File.join(directory, "test"))
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.stable?(age) = age >= 18
          def self.stateful?(age) = age >= 18
          def self.uncovered?(age) = age >= 18
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_stable
            assert Sample.stable?(19)
          end

          def test_stateful
            age = File.exist?("external-state") ? 18 : 19
            File.write("external-state", "baseline ran")
            assert Sample.stateful?(age)
          end
        end
      RUBY

      output, error, status = Open3.capture3(RbConfig.ruby, executable, "--jobs", "1", "--operators", "comparison", "--reporter",
                                             "agent", "--verify-not-infected", chdir: directory)
      expect(status).to be_success, error
      expect(JSON.parse(output).fetch("summary")).to include("not_infected" => 1, "not_reached" => 1, "killed" => 1)
      snapshot = JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json")))
      mutations = snapshot.fetch("mutants").values.to_h { |mutant| [mutant.fetch("subject"), mutant] }
      expect(mutations.fetch("Sample.stable?")).to include("status" => "not_infected", "verified" => true)
      uncovered = mutations.fetch("Sample.uncovered?")
      expect(uncovered).to include("status" => "not_reached")
      expect(uncovered).not_to have_key("verified")
      killed = mutations.fetch("Sample.stateful?")
      expect(killed).to include("status" => "killed", "verified" => true, "killed_by" => "SampleTest#test_stateful")
      expect(error.lines.grep(/verification discrepancy/).map(&:chomp)).to eq(
        ["ripr: verification discrepancy #{killed.fetch('id')}: expected not_infected, got killed"]
      )
    end
  end
end
