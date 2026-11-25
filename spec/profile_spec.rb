# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "ripr profiling" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }
  let(:fixture) { File.expand_path("../test/fixtures/projects/minitest_basic", __dir__) }

  def command(directory, *arguments)
    output, error, status = Open3.capture3(RbConfig.ruby, executable, "--jobs", "2", "--reporter", "agent",
                                           *arguments, chdir: directory)
    expect(status).to be_success, error
    JSON.parse(output)
  end

  def with_fixture
    Dir.mktmpdir("ripr-profile") do |directory|
      %w[lib test].each { |path| FileUtils.cp_r(File.join(fixture, path), directory) }
      yield directory
    end
  end

  def profile(directory, report_dir = ".ripr/report")
    JSON.parse(File.read(File.join(directory, report_dir, "profile.json")))
  end

  it "writes phase timings and actual mutation test counts without changing the agent report" do
    with_fixture do |directory|
      report = command(directory, "--profile", "--report-dir", "results")
      stats = profile(directory, "results")
      expect(report).to include("schema" => "ripr.agent/v1")
      expect(report.fetch("run").fetch("metrics")).to include("baseline_tests_run" => 2, "reused" => 0)
      expect(stats.fetch("schema")).to eq("ripr.profile/v1")
      expect(stats.fetch("phases_ms").keys).to contain_exactly("plan", "instrument", "boot", "baseline", "mutation", "report")
      expect(stats.fetch("phases_ms").values).to all(be >= 0.0)
      expect(stats.fetch("baseline")).to include("tests_run" => 2, "tests_reused" => 0)
      expect(stats.fetch("mutations")).to include("attempted" => 7, "probe_skipped" => 5, "cached" => 0, "tests_run" => 7,
                                                  "tests_per_mutation" => 1.0, "skipped_fraction" => be_within(0.0001).of(5.0 / 12))
      latency = stats.fetch("mutations").fetch("latency_ms")
      expect(latency.fetch("p50")).to be > 0.0
      expect(latency.fetch("p95")).to be >= latency.fetch("p50")
      expect(stats.fetch("mutations").fetch("attempts").map { |item| item.fetch("tests_run") }).to eq([1] * 7)
    end
  end

  it "counts reused baseline tests and cached mutant verdicts separately from new executions" do
    with_fixture do |directory|
      command(directory)
      expect(File).not_to exist(File.join(directory, ".ripr/report/profile.json"))
      command(directory, "--profile")
      stats = profile(directory)
      expect(stats.fetch("baseline")).to include("tests_run" => 0, "tests_reused" => 2, "cache_hit_fraction" => 1.0)
      expect(stats.fetch("mutations")).to include("attempted" => 0, "cached" => 12, "probe_skipped" => 0, "tests_run" => 0,
                                                  "skipped_fraction" => 1.0, "cache_hit_fraction" => 1.0,
                                                  "latency_ms" => { "p50" => nil, "p95" => nil }, "attempts" => [])
    end
  end

  it "profiles dry runs without reporting planned mutants as avoided executions" do
    with_fixture do |directory|
      command(directory, "--profile", "--dry-run")
      stats = profile(directory)
      expect(stats.fetch("phases_ms")).to include("boot" => 0.0, "baseline" => 0.0, "mutation" => 0.0)
      expect(stats.fetch("mutations")).to include("selected" => 12, "attempted" => 0, "probe_skipped" => 0,
                                                  "skipped_fraction" => nil, "cache_hit_fraction" => nil)
    end
  end

  it "marks test counts unknown for interrupted mutants and counts completed tests and replays" do
    with_fixture do |directory|
      File.write(File.join(directory, "lib/sample.rb"), "module Sample; def self.count; 1; end; end\n")
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_count
            value = Sample.count
            sleep(30) if value.zero?
            assert_equal 1, value
          end
        end
      RUBY
      report = command(directory, "--profile", "--operators", "integer_literal", "--timeout-base", "1000", "--verify-killed")
      expect(report.fetch("summary")).to include("timeout" => 1, "killed" => 1)
      stats = profile(directory)
      mutations = stats.fetch("mutations")
      expect(mutations).to include("attempted" => 2, "unknown_test_counts" => 1, "tests_run" => 1, "tests_per_mutation" => 1.0)
      expect(mutations.fetch("attempts").map { |item| item.fetch("tests_run") }).to contain_exactly(nil, 1)
      expect(stats.fetch("verification")).to include("attempted" => 1, "tests_run" => 1, "unknown_test_counts" => 0)
    end
  end
end
