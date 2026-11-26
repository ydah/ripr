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

  it "schedules mutations by their covering tests' recorded costs" do
    Dir.mktmpdir("ripr-worker-order") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.aaa_slow?(age) = age >= 18
          def self.zzz_fast?(age) = age >= 18
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_slow
            value = Sample.aaa_slow?(18)
            File.open("worker-order", "a") { |file| file.puts "slow" } unless value
            assert value
          end

          def test_fast
            value = Sample.zzz_fast?(18)
            File.open("worker-order", "a") { |file| file.puts "fast" } unless value
            assert value
          end
        end
      RUBY
      command = [RbConfig.ruby, executable, "--jobs", "1", "--operators", "comparison", "--reporter", "agent"]
      _, error, status = Open3.capture3(*command, chdir: directory)
      expect(status).to be_success, error
      path = File.join(directory, ".ripr/snapshot.json")
      snapshot = JSON.parse(File.read(path))
      snapshot.fetch("baseline").fetch("tests").fetch("SampleTest#test_slow")["duration_ms"] = 100
      snapshot.fetch("baseline").fetch("tests").fetch("SampleTest#test_fast")["duration_ms"] = 1
      ids = snapshot.fetch("mutants").values.map { |mutant| mutant.fetch("id") }
      File.write(path, JSON.generate(snapshot))
      File.write(File.join(directory, "worker-order"), "")

      output, error, status = Open3.capture3(*command, "--only", ids.join(","), chdir: directory)
      expect(status).to be_success, error
      expect(JSON.parse(output).dig("run", "metrics", "baseline_tests_run")).to eq(0)
      expect(File.readlines(File.join(directory, "worker-order"), chomp: true)).to eq(%w[fast slow])
    end
  end

  it "runs only infecting tests when a value mutation also has unchanged observations" do
    Dir.mktmpdir("ripr-infecting-tests") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), "module Sample; def self.adult?(age) = age >= 18; end\n")
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_same
            File.open("mutation-order", "a") { |file| file.puts "same" } if File.exist?("record-order")
            assert Sample.adult?(19)
          end

          def test_boundary
            File.open("mutation-order", "a") { |file| file.puts "boundary" } if File.exist?("record-order")
            assert Sample.adult?(18)
          end
        end
      RUBY
      command = [RbConfig.ruby, executable, "--jobs", "1", "--operators", "comparison", "--reporter", "agent"]
      _, error, status = Open3.capture3(*command, chdir: directory)
      expect(status).to be_success, error
      path = File.join(directory, ".ripr/snapshot.json")
      snapshot = JSON.parse(File.read(path))
      mutant = snapshot.fetch("mutants").values.fetch(0)
      snapshot.fetch("baseline").fetch("tests").fetch("SampleTest#test_same")["duration_ms"] = 1
      snapshot.fetch("baseline").fetch("tests").fetch("SampleTest#test_boundary")["duration_ms"] = 100
      snapshot["mutants"] = {}
      File.write(path, JSON.generate(snapshot))
      File.write(File.join(directory, "record-order"), "")

      output, error, status = Open3.capture3(*command, "--only", mutant.fetch("id"), chdir: directory)
      expect(status).to be_success, error
      expect(JSON.parse(output).fetch("summary")).to include("killed" => 1)
      expect(JSON.parse(output).dig("run", "metrics", "baseline_tests_run")).to eq(0)
      expect(File.readlines(File.join(directory, "mutation-order"), chomp: true)).to eq(["boundary"])
    end
  end
end

RSpec.describe "verification of probe verdicts" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }

  it "reports an original replay crash or timeout without keeping the mutant's killing test" do
    Dir.mktmpdir("ripr-replay-failure") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.crash?(age) = age >= 18
          def self.timeout?(age) = age >= 18
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_crash
            File.open("crash-runs", "a") { |file| file.puts "run" }
            exit! 23 if File.readlines("crash-runs").size == 3
            assert Sample.crash?(18)
          end

          def test_timeout
            File.open("timeout-runs", "a") { |file| file.puts "run" }
            sleep 30 if File.readlines("timeout-runs").size == 3
            assert Sample.timeout?(18)
          end
        end
      RUBY

      output, error, status = Open3.capture3(RbConfig.ruby, executable, "--jobs", "1", "--operators", "comparison",
                                             "--reporter", "agent", "--verify-killed", "--timeout-base", "500", chdir: directory)
      expect(status).to be_success, error
      expect(JSON.parse(output).fetch("summary")).to include("error" => 2, "killed" => 0, "timeout" => 0)
      snapshot = JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json")))
      results = snapshot.fetch("mutants").values.to_h { |mutant| [mutant.fetch("subject"), mutant] }
      details = { "Sample.crash?" => "child exited without a valid result", "Sample.timeout?" => "timeout" }
      details.each do |subject, detail|
        result = results.fetch(subject)
        message = "could not verify kill #{result.fetch('id')} on original code (#{detail})"
        expect(result).to include("status" => "error", "killed_by" => nil, "error" => message)
        expect(result.keys).not_to include("test_ids", "verification_status")
        expect(error).to include(message)
      end
      %w[crash timeout].each do |name|
        expect(File.readlines(File.join(directory, "#{name}-runs"), chomp: true)).to eq(%w[run run run])
      end
    end
  end

  it "preserves a crashed worker's error without replaying it as a killed mutation" do
    Dir.mktmpdir("ripr-worker-verdict") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.crash?(age) = age >= 18
          def self.boundary?(age) = age >= 18
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_crash
            File.open("crash-tests", "a") { |file| file.puts "run" }
            exit! 23 unless Sample.crash?(18)
            assert true
          end

          def test_boundary
            assert Sample.boundary?(18)
          end
        end
      RUBY

      output, error, status = Open3.capture3(RbConfig.ruby, executable, "--jobs", "1", "--operators", "comparison",
                                             "--reporter", "agent", "--verify-killed", chdir: directory)
      expect(status).to be_success, error
      expect(JSON.parse(output).fetch("summary")).to include("error" => 1, "killed" => 1)
      snapshot = JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json")))
      results = snapshot.fetch("mutants").values.to_h { |mutant| [mutant.fetch("subject"), mutant] }
      expect(results.fetch("Sample.crash?")).to include(
        "status" => "error", "killed_by" => nil, "error" => "child exited without a valid result"
      )
      expect(results.fetch("Sample.boundary?")).to include(
        "status" => "killed", "killed_by" => "SampleTest#test_boundary", "error" => nil
      )
      expect(File.readlines(File.join(directory, "crash-tests"), chomp: true)).to eq(%w[run run])
      expect(error).not_to include("could not verify kill")
    end
  end

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

RSpec.describe "verification of probe verdicts" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }

  it "preserves a crashed worker's error without replaying it as a killed mutation" do
    Dir.mktmpdir("ripr-worker-verdict") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.crash?(age) = age >= 18
          def self.boundary?(age) = age >= 18
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_crash
            File.open("crash-tests", "a") { |file| file.puts "run" }
            exit! 23 unless Sample.crash?(18)
            assert true
          end

          def test_boundary
            assert Sample.boundary?(18)
          end
        end
      RUBY

      output, error, status = Open3.capture3(RbConfig.ruby, executable, "--jobs", "1", "--operators", "comparison",
                                             "--reporter", "agent", "--verify-killed", chdir: directory)
      expect(status).to be_success, error
      expect(JSON.parse(output).fetch("summary")).to include("error" => 1, "killed" => 1)
      snapshot = JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json")))
      results = snapshot.fetch("mutants").values.to_h { |mutant| [mutant.fetch("subject"), mutant] }
      expect(results.fetch("Sample.crash?")).to include(
        "status" => "error", "killed_by" => nil, "error" => "child exited without a valid result"
      )
      expect(results.fetch("Sample.boundary?")).to include(
        "status" => "killed", "killed_by" => "SampleTest#test_boundary", "error" => nil
      )
      expect(File.readlines(File.join(directory, "crash-tests"), chomp: true)).to eq(%w[run run])
      expect(error).not_to include("could not verify kill")
    end
  end

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
