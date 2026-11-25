# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/ripr/engine/shard_plan"

RSpec.describe "ripr shared shard plan" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }

  def git(directory, *args)
    output, error, status = Open3.capture3("git", "-C", directory, "-c", "maintenance.auto=false", *args)
    raise error unless status.success?

    output.strip
  end

  def command(directory, *args, env: {}, exit_code: 0)
    output, error, status = Open3.capture3(env, RbConfig.ruby, executable, *args, "--operators", "comparison", chdir: directory)
    expect(status.exitstatus).to eq(exit_code), error
    [output, error]
  end

  def with_project(spec_source: nil)
    Dir.mktmpdir("ripr-shards") do |directory|
      FileUtils.mkdir_p(File.join(directory, "lib"))
      File.write(File.join(directory, "lib/subject.rb"), <<~SOURCE)
        class Subject
          def self.low?(value) = value < 5
          def self.high?(value) = value > 10
          def self.unobserved?(value) = value >= 5
        end
      SOURCE
      test_source = <<~SOURCE
        require "minitest/autorun"
        require_relative "../lib/subject"

        class SubjectTest < Minitest::Test
          def test_low
            assert_equal false, Subject.low?(5)
          end

          def test_high
            assert_equal false, Subject.high?(10)
          end
        end
      SOURCE
      test_dir, basename = spec_source ? %w[spec subject_spec.rb] : %w[test subject_test.rb]
      FileUtils.mkdir_p(File.join(directory, test_dir))
      File.write(File.join(directory, test_dir, basename), spec_source || test_source)
      git(directory, "init", "-q")
      commit(directory)
      yield directory
    end
  end

  def commit(directory)
    git(directory, "add", "lib", File.directory?(File.join(directory, "test")) ? "test" : "spec")
    git(directory, "-c", "user.name=Ripr Test", "-c", "user.email=test@example.test", "commit", "-qm", "fixture")
  end

  def json(directory, path)
    JSON.parse(File.read(File.join(directory, path)))
  end

  it "plans one baseline and runs disjoint slices without replacing the ordinary snapshot" do
    with_project do |directory|
      command(directory, "--full")
      snapshot = File.binread(File.join(directory, ".ripr/snapshot.json"))
      expected = JSON.parse(snapshot).fetch("mutants").transform_values { |result| result.fetch("status") }

      command(directory, "shard-plan", "2")
      plan = json(directory, ".ripr/shard-plan.json")
      expect(plan.dig("report", "run", "metrics", "baseline_tests_run")).to eq(2)
      expect(plan.fetch("shards").flatten).to match_array(expected.keys)
      expect(plan.fetch("shards").map(&:size)).to all(be_positive)
      fragments = (1..2).flat_map do |index|
        output, = command(directory, "--shard", "#{index}/2", "--report-dir", ".ripr/shard-#{index}", "--reporter", "agent",
                          "--fail-on-survived", "--threshold", "100")
        expect(JSON.parse(output).dig("run", "metrics", "baseline_tests_run")).to eq(0)
        fragment = json(directory, ".ripr/shard-#{index}/shard.json")
        expect(fragment).to include("version" => 1, "index" => index, "total" => 2, "plan_digest" => match(/\A[0-9a-f]{64}\z/))
        expect(fragment.fetch("results").map { |result| result.fetch("full_id") }).to match_array(plan.fetch("shards").fetch(index - 1))
        fragment.fetch("results")
      end
      expect(fragments.to_h { |result| result.values_at("full_id", "status") }).to eq(expected)
      expect(File.binread(File.join(directory, ".ripr/snapshot.json"))).to eq(snapshot)
    end
  end

  it "assigns the longest candidate first and resolves equal weights deterministically" do
    costs = { "zero-b" => 0, "slow" => 9, "equal-b" => 4, "medium" => 7, "equal-a" => 4, "zero-a" => 0 }
    shards = Ripr::Engine::ShardPlan.assign(costs, 2)
    expect(shards).to eq([%w[slow equal-b], %w[medium equal-a zero-a zero-b]])
    expect(shards.map { |ids| ids.sum { |id| costs.fetch(id) } }).to eq([13, 11])
    expect(Ripr::Engine::ShardPlan.assign(costs.to_a.reverse.to_h, 2)).to eq(shards)
  end

  it "emits an empty fragment without booting when the diff has no mutations" do
    with_project do |directory|
      command(directory, "shard-plan", "2", "--since", "HEAD", "--shard-plan", ".ripr/empty.json")
      plan = json(directory, ".ripr/empty.json")
      expect(plan.fetch("shards")).to eq([[], []])
      expect(plan.fetch("cache")).to be_nil
      expect(plan.dig("report", "run", "metrics", "baseline_tests_run")).to eq(0)

      command(directory, "--shard", "2/2", "--since", "HEAD", "--shard-plan", ".ripr/empty.json")
      expect(json(directory, ".ripr/report/shard.json").fetch("results")).to be_empty
      expect(File.exist?(File.join(directory, ".ripr/snapshot.json"))).to be(false)
    end
  end

  it "retains RSpec pending outcomes while requiring every runnable test in the baseline" do
    spec = <<~SOURCE
      require_relative "../lib/subject"

      RSpec.describe Subject do
        it("checks low") { expect(Subject.low?(5)).to be(false) }
        xit("checks high") { expect(Subject.high?(10)).to be(false) }
      end
    SOURCE
    with_project(spec_source: spec) do |directory|
      command(directory, "shard-plan", "2")
      plan = json(directory, ".ripr/shard-plan.json")
      expect(plan.dig("baseline", "outcomes").values).to contain_exactly("passed", "pending")
      command(directory, "--shard", "1/2", "--reporter", "agent")
    end
  end

  it "rejects a changed runtime environment and missing plan" do
    with_project do |directory|
      _, error = command(directory, "--shard", "1/2", exit_code: 1)
      expect(error).to include("shard plan")
      command(directory, "shard-plan", "2")
      _, error = command(directory, "--shard", "1/2", env: { "RIPR_FIXTURE_CHANGED" => "1" }, exit_code: 1)
      expect(error).to include("shard plan").and include("match")
      expect(File.exist?(File.join(directory, ".ripr/report/shard.json"))).to be(false)
    end
  end

  it "includes formerly reached mutations after a test-only diff" do
    with_project do |directory|
      before = git(directory, "rev-parse", "HEAD")
      path = File.join(directory, "test/subject_test.rb")
      File.write(path, File.read(path).sub("assert_equal false, Subject.low?(5)", "assert true"))
      commit(directory)

      command(directory, "shard-plan", "1", "--since", before, "--include-tests-diff")
      command(directory, "--shard", "1/1", "--since", before, "--include-tests-diff")
      results = json(directory, ".ripr/report/shard.json").fetch("results")
      expect(results).to include(a_hash_including("subject" => "Subject.low?", "status" => "not_reached"))
    end
  end

  it "rejects duplicated IDs, malformed baseline observations, or a new HEAD" do
    with_project do |directory|
      command(directory, "shard-plan", "2")
      path = File.join(directory, ".ripr/shard-plan.json")
      original = File.binread(path)
      plan = JSON.parse(original)
      ids = plan.fetch("shards")
      ids.last << ids.first.first
      File.write(path, JSON.generate(plan))
      _, error = command(directory, "--shard", "1/2", exit_code: 1)
      expect(error).to include("invalid shard plan")

      plan = JSON.parse(original)
      baseline = plan.fetch("baseline")
      dropped = baseline.fetch("tests").keys.first
      baseline.fetch("tests").delete(dropped)
      baseline.fetch("probe").values.grep(Hash).each { |entries| entries.each_value { |members| members.delete(dropped) } }
      File.write(path, JSON.generate(plan))
      _, error = command(directory, "--shard", "1/2", exit_code: 1)
      expect(error).to include("complete test outcomes")

      File.write(path, original)
      git(directory, "-c", "user.name=Ripr Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-qm", "new revision")
      _, error = command(directory, "--shard", "1/2", exit_code: 1)
      expect(error).to include("does not match the checkout")
    end
  end

  it "declines to publish a baseline that used an ignored file outside the verified test fixtures" do
    with_project do |directory|
      FileUtils.mkdir_p(File.join(directory, ".ripr"))
      File.write(File.join(directory, ".ripr/dependency"), "5")
      File.open(File.join(directory, "test/subject_test.rb"), "a") do |file|
        file.write(<<~SOURCE)
          class SubjectTest
            def test_hidden_input
              assert_equal false, Subject.low?(File.read(".ripr/dependency").to_i)
            end
          end
        SOURCE
      end
      commit(directory)
      _, error = command(directory, "shard-plan", "2", exit_code: 4)
      expect(error).to include("shard plan cannot verify test inputs")
      expect(File.exist?(File.join(directory, ".ripr/shard-plan.json"))).to be(false)
    end
  end

  it "leaves reserved outputs and existing non-plan files intact" do
    with_project do |directory|
      source = File.join(directory, "lib/subject.rb")
      before = File.binread(source)
      _, error = command(directory, "shard-plan", "2", "--shard-plan", "lib/subject.rb", exit_code: 1)
      expect(error).to include("existing non-plan file")
      expect(File.binread(source)).to eq(before)

      _, error = command(directory, "shard-plan", "2", "--report-dir", ".ripr/worker", "--shard-plan", ".ripr/worker/profile.json",
                         exit_code: 1)
      expect(error).to include("cannot replace a report or the ordinary snapshot")
    end
  end

  {
    boot: "loaded tests, boot inputs, or database",
    baseline: "Ruby dependencies loaded by the baseline"
  }.each do |phase, message|
    it "rejects changed Ruby dependencies loaded during #{phase}" do
      with_project do |directory|
        FileUtils.mkdir_p(File.join(directory, ".ripr"))
        dependency = File.join(directory, ".ripr/support.rb")
        File.write(dependency, "SHARD_TEST_DEPENDENCY = 5\n")
        line = 'require_relative "../.ripr/support"'
        helpers = phase == :boot ? line : "    #{line}"
        File.write(File.join(directory, "test/subject_test.rb"), <<~SOURCE)
          require "minitest/autorun"
          require_relative "../lib/subject"
          #{helpers if phase == :boot}

          class SubjectTest < Minitest::Test
            def test_low
              #{helpers if phase == :baseline}
              assert_equal false, Subject.low?(SHARD_TEST_DEPENDENCY)
            end
          end
        SOURCE
        commit(directory)
        command(directory, "shard-plan", "2")
        File.write(dependency, "SHARD_TEST_DEPENDENCY = 9\n")
        _, error = command(directory, "--shard", "1/2", exit_code: 1)
        expect(error).to include(message)
      end
    end
  end

  it "rejects a changed preloaded Ruby dependency" do
    with_project do |directory|
      FileUtils.mkdir_p(File.join(directory, ".ripr"))
      dependency = File.join(directory, ".ripr/preload.rb")
      env = { "RUBYOPT" => "#{ENV.fetch('RUBYOPT', '')} -r#{dependency}" }
      File.write(dependency, "SHARD_PRELOADED = 1\n")
      command(directory, "shard-plan", "2", env:)
      File.write(dependency, "SHARD_PRELOADED = 2\n")
      _, error = command(directory, "--shard", "1/2", env:, exit_code: 1)
      expect(error).to include("does not match the checkout, runtime")
    end
  end
end
