# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

RSpec.describe "ripr command" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }
  let(:fixture) { File.expand_path("../test/fixtures/projects/minitest_basic", __dir__) }

  def command(*args, directory: fixture, env: {})
    Open3.capture3(env, RbConfig.ruby, executable, *args, chdir: directory)
  end

  it "classifies Minitest gaps and emits clean agent JSON" do
    stdout, stderr, status = command("--reporter", "agent", "--full", "--jobs", "2")
    expect(status.exitstatus).to eq(0), stderr
    report = JSON.parse(stdout)
    expect(report.fetch("schema")).to eq("ripr.agent/v1")
    boundary = report.fetch("gaps").find { |m| m["subject"] == "Sample.adult?" && m["operator"] == "comparison" }
    expect(boundary.fetch("kind")).to eq("not_infected")
    expect(boundary.fetch("observed")).to eq([[20, 18], [10, 18]])
    expect(report.fetch("summary").fetch("killed")).to be >= 2
    expect(report.fetch("summary").fetch("not_reached")).to be >= 1
  end

  it "produces equivalent classifications for RSpec" do
    rspec_fixture = fixture.sub("minitest_basic", "rspec_basic")
    stdout, stderr, status = command("--reporter", "agent", "--full", directory: rspec_fixture)
    expect(status.exitstatus).to eq(0), stderr
    boundary = JSON.parse(stdout).fetch("gaps").find { |m| m["operator"] == "comparison" }
    expect(boundary.fetch("kind")).to eq("not_infected")
  end

  it "matches the design's complete golden classifications for both frameworks" do
    expected = JSON.parse(File.read(File.expand_path("../test/fixtures/golden/basic.json", __dir__)))
    %w[minitest rspec].each do |framework|
      directory = fixture.sub("minitest_basic", "#{framework}_basic")
      _, stderr, status = command("--full", directory: directory)
      expect(status.exitstatus).to eq(0), stderr
      snapshot = JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json")))
      actual = snapshot.fetch("mutants").values.map { |m| m.slice("subject", "operator", "replacement", "status") }
      sort_key = ->(m) { m.values_at("subject", "operator", "replacement") }
      expect(actual.sort_by(&sort_key)).to eq(expected.sort_by(&sort_key))
    end
  end

  it "validates options and configuration before running tests" do
    _, _, status = command("--jobs", "0")
    expect(status.exitstatus).to eq(1)
    _, _, status = command("--scope", "other")
    expect(status.exitstatus).to eq(1)
    Dir.mktmpdir("ripr-config") do |dir|
      File.write(File.join(dir, ".ripr.yml"), "unknown: 1\n")
      _, stderr, status = command(directory: dir)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("unknown")
    end
  end

  it "returns quality gate and baseline failure exit codes" do
    _, _, status = command("--fail-on-survived", "--full")
    expect(status.exitstatus).to eq(2)
    Dir.mktmpdir("ripr-failure") do |dir|
      FileUtils.cp_r(File.join(fixture, "."), dir)
      File.write(File.join(dir, "test/sample_test.rb"),
                 "require 'minitest/autorun'; class BrokenTest < Minitest::Test; def test_broken; flunk; end; end")
      _, _, status = command("--full", directory: dir)
      expect(status.exitstatus).to eq(4)
    end
  end

  it "kills arithmetic mutations when tests catch an exception from the original operator" do
    Dir.mktmpdir("ripr-exception") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "test"))
      File.write(File.join(dir, "lib/sample.rb"), "module Sample; def self.divide(n, d); n / d; end; end\n")
      File.write(File.join(dir, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class DivideTest < Minitest::Test
          def test_zero_divisor
            assert_raises(ZeroDivisionError) { Sample.divide(4, 0) }
          end
        end
      RUBY
      _, stderr, status = command("--full", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      snapshot = JSON.parse(File.read(File.join(dir, ".ripr/snapshot.json")))
      arithmetic = snapshot.fetch("mutants").values.find { |mutant| mutant["operator"] == "arithmetic" }
      expect(arithmetic.fetch("status")).to eq("killed")
    end
  end

  it "initializes configuration and the bundled skill without overwriting changes" do
    Dir.mktmpdir("ripr-init") do |dir|
      _, stderr, status = command("init", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      expect(File.read(File.join(dir, ".ripr.yml"))).to include("framework: auto")
      _, stderr, status = command("init-skill", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      target = File.join(dir, ".claude/skills/mutation-test-loop/SKILL.md")
      bundled = File.expand_path("../skills/mutation-test-loop/SKILL.md", __dir__)
      expect(File.read(target)).to eq(File.read(bundled))
      File.write(target, "customized")
      _, _, status = command("init-skill", directory: dir)
      expect(status.exitstatus).to eq(1)
      expect(File.read(target)).to eq("customized")
      _, _, status = command("init-skill", "--force", directory: dir)
      expect(status.exitstatus).to eq(0)
      expect(File.read(target)).to eq(File.read(bundled))
    end
  end

  it "lists operators and writes JSON and offline HTML reports" do
    stdout, _, status = command("list", "operators")
    expect(status.exitstatus).to eq(0)
    expect(stdout.lines.map(&:strip)).to include("comparison", "return_nil")
    stdout, _, status = command("list", "mutants")
    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("age >= 18")
    Dir.mktmpdir("ripr-report") do |dir|
      _, stderr, status = command("--reporter", "html", "--reporter", "json", "--report-dir", dir, "--full")
      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(File.read(File.join(dir, "mutation.json"))).fetch("schemaVersion")).to eq("2")
      expect(File.read(File.join(dir, "index.html"))).to include("ripr mutation report")
    end
  end

  it "uses workspace-relative annotation paths when run in a nested project" do
    workspace = File.expand_path("..", __dir__)
    output, stderr, status = command("--reporter", "github", "--full", env: { "GITHUB_WORKSPACE" => workspace })
    expect(status.exitstatus).to eq(0), stderr
    expect(output).to include("::warning file=test/fixtures/projects/minitest_basic/lib/sample.rb,")
  end

  it "annotates sites that ran while loading and cannot change existing load-time effects" do
    Dir.mktmpdir("ripr-load-reach") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "test"))
      File.write(File.join(dir, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.adult?(age); age >= 18; end
          ADULT = adult?(20)
        end
      RUBY
      File.write(File.join(dir, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class LoadTest < Minitest::Test
          def test_constant
            assert Sample::ADULT
          end
        end
      RUBY
      output, stderr, status = command("--reporter", "agent", "--operators", "comparison", "--full", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      gap = JSON.parse(output).fetch("gaps").first
      expect(gap.fetch("load_reached")).to be(true)
      expect(gap.fetch("hint")).to include("during loading")
    end
  end

  it "accepts equivalent mutants and invalidates the acceptance after source changes" do
    Dir.mktmpdir("ripr-accept") do |dir|
      FileUtils.cp_r(File.join(fixture, "."), dir)
      stdout, stderr, status = command("--reporter", "agent", "--full", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      gap = JSON.parse(stdout).fetch("gaps").find { |m| m["operator"] == "comparison" }
      _, stderr, status = command("accept", gap.fetch("id"), "--reason", "Specification excludes the exact boundary", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      stdout, stderr, status = command("--reporter", "agent", "--full", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(stdout).fetch("summary").fetch("accepted")).to eq(1)
      source_path = File.join(dir, "lib/sample.rb")
      File.write(source_path, File.read(source_path).sub("age >= 18", "age >= 19"))
      stdout, stderr, status = command("--reporter", "agent", "--full", directory: dir)
      expect(status.exitstatus).to eq(0), stderr
      expect(JSON.parse(stdout).fetch("summary").fetch("accepted")).to eq(0)
      expect(stderr).to include("stale")
    end
  end
end
