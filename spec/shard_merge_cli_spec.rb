# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "ripr merge" do
  let(:root) { File.expand_path("..", __dir__) }

  def in_project(test_source: nil)
    Dir.mktmpdir("ripr-shard-aggregate") do |directory|
      fixture = File.join(root, "test/fixtures/projects/minitest_basic")
      %w[lib test].each { |path| FileUtils.cp_r(File.join(fixture, path), directory) }
      File.write(File.join(directory, "test/sample_test.rb"), test_source) if test_source
      File.write(File.join(directory, ".gitignore"), ".ripr/\ntest/fixtures/\n")
      %w[init add commit].zip([["-q"], ["."], ["-qm", "fixture"]]).each do |command, arguments|
        _, error, status = Open3.capture3("git", "-c", "user.name=Ripr", "-c", "user.email=ripr@example.test",
                                          "-c", "maintenance.auto=false", command, *arguments, chdir: directory)
        expect(status).to be_success, error
      end
      yield directory
    end
  end

  def ripr(directory, *arguments, expected: 0, environment: {})
    output, error, status = Open3.capture3(environment, RbConfig.ruby, File.join(root, "exe/ripr"),
                                           *arguments, "--jobs", "1", "--no-samples", chdir: directory)
    expect(status.exitstatus).to eq(expected), error
    yield error if block_given?
    output
  end

  it "rejects a different merge environment and ignores a merged cache when runtime inputs or dependencies change" do
    test = <<~RUBY
      require "minitest/autorun"
      require_relative "../lib/sample"
      require_relative "../.ripr/feature"
      class SampleTest < Minitest::Test
        def test_adult
          assert Sample.adult?(18) if ENV["RIPR_FRAGMENT_TEST"] == "enabled" && SHARD_MERGE_FEATURE
        end
      end
    RUBY
    in_project(test_source: test) do |directory|
      FileUtils.mkdir_p(File.join(directory, ".ripr"))
      dependency = File.join(directory, ".ripr/feature.rb")
      File.write(dependency, "SHARD_MERGE_FEATURE = true\n")
      enabled = { "RIPR_FRAGMENT_TEST" => "enabled" }
      disabled = { "RIPR_FRAGMENT_TEST" => "disabled" }
      options = %w[--operators comparison --reporter agent]
      ripr(directory, "shard-plan", "1", *options, environment: enabled)
      ripr(directory, "--shard", "1/1", *options, environment: enabled)
      snapshot = File.join(directory, ".ripr/snapshot.json")
      File.write(snapshot, "snapshot sentinel")

      fragment = ".ripr/report/shard.json"
      ripr(directory, "merge", fragment, *options, environment: disabled, expected: 1) do |error|
        expect(error).to include("does not match the merge runtime")
      end
      expect(File.binread(snapshot)).to eq("snapshot sentinel")

      merged = ripr(directory, "merge", fragment, *options, environment: enabled)
      expect(JSON.parse(merged).fetch("summary")).to include("killed" => 1)
      reused = ripr(directory, *options, environment: enabled)
      expect(JSON.parse(reused).dig("run", "metrics", "reused")).to eq(1)
      changed = JSON.parse(ripr(directory, *options, environment: disabled))
      expect(changed.dig("run", "metrics")).to include("reused" => 0, "baseline_tests_run" => 1)
      expect(changed.fetch("summary")).to include("killed" => 0, "not_reached" => 1)

      ripr(directory, "merge", fragment, *options, environment: enabled)
      saved = File.binread(snapshot)
      File.write(dependency, "SHARD_MERGE_FEATURE = false\n")
      ripr(directory, "merge", fragment, *options, environment: enabled, expected: 1) do |error|
        expect(error).to include("shard plan test, Ruby, or boot inputs have changed")
      end
      expect(File.binread(snapshot)).to eq(saved)
      changed = JSON.parse(ripr(directory, *options, environment: enabled))
      expect(changed.dig("run", "metrics")).to include("reused" => 0, "baseline_tests_run" => 1)
      expect(changed.fetch("summary")).to include("killed" => 0, "not_reached" => 1)
    end
  end

  def merged_body(stdout)
    report = JSON.parse(stdout).slice("summary", "gaps", "methods", "weak_tests")
    report.fetch("gaps").each { |gap| gap.fetch("covering_tests").each { |test| test.delete("duration_ms") } }
    report
  end

  it "rejects a changed ignored test fixture before publishing a merged result" do
    test = <<~RUBY
      require "minitest/autorun"
      require_relative "../lib/sample"
      class SampleTest < Minitest::Test
        def test_adult
          fixture = File.open(File.expand_path("fixtures/feature.txt", __dir__))
          assert Sample.adult?(18) if fixture.read == "enabled"
        ensure
          fixture&.close
        end
      end
    RUBY
    in_project(test_source: test) do |directory|
      fixture = File.join(directory, "test/fixtures/feature.txt")
      FileUtils.mkdir_p(File.dirname(fixture))
      File.write(fixture, "enabled")
      options = %w[--operators comparison]
      ripr(directory, "shard-plan", "1", *options)
      ripr(directory, "--shard", "1/1", *options)

      File.write(fixture, "disabled")
      ripr(directory, "merge", ".ripr/report/shard.json", *options, expected: 1) do |error|
        expect(error).to include("shard plan test, Ruby, or boot inputs have changed")
      end
      expect(File).not_to exist(File.join(directory, ".ripr/snapshot.json"))
    end
  end

  it "aggregates all verdicts and rebuilds the cache before applying the project gate" do
    in_project do |directory|
      ripr(directory, "shard-plan", "2")
      parts = [2, 1].map do |index|
        path = ".ripr/part-#{index}"
        output = ripr(directory, "--shard", "#{index}/2", "--report-dir", path, "--reporter", "agent-v2")
        expect(JSON.parse(output).dig("run", "metrics", "baseline_tests_run")).to eq(0)
        File.join(path, "shard.json")
      end
      snapshot = File.join(directory, ".ripr/snapshot.json")
      expect(File).not_to exist(snapshot)
      merged = ripr(directory, "merge", *parts, "--reporter", "agent-v2", "--reporter", "json",
                    "--report-dir", ".ripr/merged", "--fail-on-survived", expected: 2)
      expect(JSON.parse(merged).dig("run", "metrics", "baseline_tests_run")).to eq(2)
      records = JSON.parse(File.read(snapshot)).fetch("mutants")
      expect(records.values.map { |result| result.fetch("status") }.uniq).to include("killed", "not_reached")

      cached = ripr(directory, "--reporter", "agent-v2")
      expect(JSON.parse(cached).dig("run", "metrics")).to include("baseline_tests_run" => 0, "reused" => records.size)
      expect(merged_body(cached)).to eq(merged_body(merged))
      ordinary = ripr(directory, "--full", "--reporter", "agent-v2", "--reporter", "json", "--report-dir", ".ripr/ordinary")
      expect(merged_body(ordinary)).to eq(merged_body(merged))
      assert_mte_matches(directory, "merged", "ordinary")
    end
  end

  it "keeps the existing snapshot and reports when a shard is missing" do
    in_project do |directory|
      ripr(directory, "shard-plan", "2")
      ripr(directory, "--shard", "1/2", "--report-dir", ".ripr/part")
      snapshot = File.join(directory, ".ripr/snapshot.json")
      output = File.join(directory, ".ripr/part/mutation.json")
      File.write(snapshot, "snapshot sentinel")
      File.write(output, "report sentinel")

      ripr(directory, "merge", ".ripr/part/shard.json", "--reporter", "json", "--report-dir", ".ripr/part", expected: 1) do |error|
        expect(error).to include("missing shard results")
      end
      expect(File.binread(snapshot)).to eq("snapshot sentinel")
      expect(File.binread(output)).to eq("report sentinel")

      ripr(directory, "--shard", "2/2", "--report-dir", ".ripr/other")
      FileUtils.cp(File.join(directory, ".ripr/part/shard.json"), output)
      original = File.binread(output)
      ripr(directory, "merge", ".ripr/part/mutation.json", ".ripr/other/shard.json", "--reporter", "json",
           "--report-dir", ".ripr/part", expected: 1) do |error|
        expect(error).to include("shard merge outputs cannot replace their inputs")
      end
      expect(File.binread(output)).to eq(original)
      expect(File.binread(snapshot)).to eq("snapshot sentinel")
    end
  end

  def assert_mte_matches(directory, left, right)
    reports = [left, right].map do |folder|
      report = JSON.parse(File.binread(File.join(directory, ".ripr", folder, "mutation.json")))
      report.fetch("files").each_value { |data| data.fetch("mutants").sort_by! { |mutant| mutant.fetch("id") } }
      report
    end
    expect(reports.first).to eq(reports.last)
  end
end
