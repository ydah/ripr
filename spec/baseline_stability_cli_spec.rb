# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "ripr repeated baselines" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }

  def with_project(tests, framework: :minitest)
    Dir.mktmpdir("ripr-stability") do |directory|
      Dir.chdir(directory) do
        Dir.mkdir("lib")
        File.write("lib/sample.rb", "module Sample; def self.adult?(age); age >= 18; end; end\n")
        if framework == :minitest
          Dir.mkdir("test")
          File.write("test/sample_test.rb", <<~RUBY)
            require "minitest/autorun"
            require "sample"
            class SampleTest < Minitest::Test
              #{tests}
            end
          RUBY
        else
          Dir.mkdir("spec")
          File.write("spec/sample_spec.rb", <<~RUBY)
            require "sample"
            RSpec.describe Sample do
              #{tests}
            end
          RUBY
        end
        yield
      end
    end
  end

  def command(*arguments, expected: 0)
    output, error, status = Open3.capture3(RbConfig.ruby, executable, "--reporter", "agent", "--operators", "comparison", *arguments)
    expect(status.exitstatus).to eq(expected), error
    [output.empty? ? nil : JSON.parse(output), error]
  end

  it "quarantines changing outcomes, reports observed time and randomness, and uses a fresh retained baseline" do
    with_project(<<~RUBY) do
      def test_flaky
        Time.now
        rand
        seen = File.exist?("marker")
        File.write("marker", "seen")
        refute seen
      end

      def test_stable
        assert Sample.adult?(18)
      end
    RUBY
      report, warnings = command("--baseline-runs", "2")
      expect(warnings).to include("SampleTest#test_flaky", "outcome changed", "clock", "random")
      expect(report.fetch("summary").fetch("killed")).to eq(1)
      expect(report.fetch("run").fetch("metrics")).to include("baseline_tests_run" => 6, "reused" => 0)
      expect(File).not_to exist(".ripr/snapshot.json")
    end
  end

  it "quarantines variable mutation reach even when both test outcomes pass" do
    with_project(<<~RUBY) do
      def test_conditional
        Sample.adult?(18) unless File.exist?("marker")
        File.write("marker", "seen")
        assert true
      end

      def test_stable
        assert true
      end
    RUBY
      report, warnings = command("--baseline-runs", "2")
      expect(warnings).to include("SampleTest#test_conditional", "mutation reach changed")
      expect(report.fetch("summary").fetch("not_reached")).to eq(1)
    end
  end

  it "quarantines varying infection when the test still reaches the same mutation" do
    with_project(<<~RUBY) do
      def test_conditional
        assert Sample.adult?(File.exist?("marker") ? 21 : 18)
        File.write("marker", "seen")
      end

      def test_stable
        assert Sample.adult?(18)
      end
    RUBY
      report, warnings = command("--baseline-runs", "2")
      expect(warnings).to include("test_conditional: mutation infection changed")
      expect(report.fetch("summary").fetch("killed")).to eq(1)
    end
  end

  it "fails if a test always fails even when its mutation reach changes" do
    with_project(<<~RUBY) do
      def test_failing
        Sample.adult?(18) unless File.exist?("marker")
        File.write("marker", "seen")
        flunk "always fails"
      end

      def test_stable
        assert Sample.adult?(18)
      end
    RUBY
      _report, error = command("--baseline-runs", "2", expected: 4)
      expect(error).to include("SampleTest#test_failing", "always fails")
    end
  end

  it "fails when quarantining a test makes a previously passing test fail" do
    with_project(<<~RUBY) do
      def test_flaky
        $initialized = true
        seen = File.exist?("marker")
        File.write("marker", "seen")
        refute seen
      end

      def test_stable
        assert $initialized, "requires setup from another test"
        assert Sample.adult?(18)
      end
    RUBY
      _report, error = command("--baseline-runs", "2", expected: 4)
      expect(error).to include("SampleTest#test_flaky", "requires setup from another test")
    end
  end

  it "does not credit a kill when a retained test fails alone on original code" do
    with_project(<<~RUBY) do
      def test_a_flaky
        seen = File.exist?("marker")
        File.write("marker", "seen")
        refute seen
      end

      def test_b_sets_up_state
        $initialized = true
        assert true
      end

      def test_c_covers_mutation
        assert $initialized, "requires setup from another test"
        assert Sample.adult?(18)
      end
    RUBY
      report, warnings = command("--baseline-runs", "2")
      expect(warnings).to include("could not verify kill", "requires setup from another test")
      expect(report.fetch("summary")).to include("killed" => 0, "error" => 1)
    end
  end

  it "rejects a stable failing baseline" do
    with_project("def test_failing; assert Sample.adult?(17), 'always fails'; end") do
      _report, error = command("--baseline-runs", "2", expected: 4)
      expect(error).to include("always fails")
    end
  end

  it "fails when no stable test remains" do
    with_project(<<~RUBY) do
      def test_flaky
        Sample.adult?(18)
        seen = File.exist?("marker")
        File.write("marker", "seen")
        refute seen
      end
    RUBY
      _report, error = command("--baseline-runs", "2", expected: 4)
      expect(error).to include("SampleTest#test_flaky", "no stable tests remain")
    end
  end

  it "detects an RSpec example changing between pending and passed" do
    with_project(<<~RUBY, framework: :rspec) do
      it "changes outcome" do
        seen = File.exist?("marker")
        File.write("marker", "seen")
        skip "not run this time" unless seen
      end

      it "kills the mutant" do
        expect(Sample.adult?(18)).to eq(true)
      end
    RUBY
      report, warnings = command("--baseline-runs", "2")
      expect(warnings).to include("sample_spec.rb", "outcome changed")
      expect(report.fetch("summary").fetch("killed")).to eq(1)
    end
  end

  it "fails when only a declared RSpec skip remains after quarantine" do
    with_project(<<~RUBY, framework: :rspec) do
      RSpec.configure { |config| config.before(:suite) { Sample.adult?(18) } }

      it "changes outcome" do
        seen = File.exist?("marker")
        File.write("marker", "seen")
        expect(seen).to be(false)
      end

      it "is always skipped", skip: true do
        raise "must never run"
      end
    RUBY
      _report, error = command("--baseline-runs", "2", expected: 4)
      expect(error).to include("sample_spec.rb", "quarantined", "no stable tests remain")
    end
  end

  it "fails if mutation reach changes outside an example" do
    with_project(<<~RUBY, framework: :rspec) do
      before(:context) do
        Sample.adult?(18) unless File.exist?("marker")
        File.write("marker", "seen")
      end

      it "kills the mutant" do
        expect(Sample.adult?(18)).to eq(true)
      end
    RUBY
      _report, error = command("--baseline-runs", "2", expected: 4)
      expect(error).to include("unattributed mutation reach changed")
    end
  end

  it "reports a suite failure even when an example also fails" do
    with_project(<<~RUBY, framework: :rspec) do
      RSpec.configure { |config| config.after(:suite) { raise "suite failure" } }

      it "fails" do
        expect(Sample.adult?(17)).to eq(true)
      end
    RUBY
      _report, error = command("--baseline-runs", "2", expected: 4)
      expect(error).to include("suite failure")
    end
  end

  it "preserves a previous snapshot and still reruns a stable baseline" do
    with_project("def test_stable; assert Sample.adult?(18); end") do
      command
      snapshot = File.binread(".ripr/snapshot.json")
      report, = command("--baseline-runs", "3")
      expect(report.fetch("run").fetch("metrics")).to include("baseline_tests_run" => 3, "reused" => 0)
      expect(File.binread(".ripr/snapshot.json")).to eq(snapshot)
    end
  end

  it "rejects a zero baseline count" do
    _report, error = command("--baseline-runs", "0", expected: 1)
    expect(error).to include("baseline-runs must be a positive integer")
  end
end
