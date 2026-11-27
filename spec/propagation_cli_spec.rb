# frozen_string_literal: true

require "fileutils"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "method-exit mutation diagnosis" do
  it "reports a changed implicit return after many nil returns" do
    Dir.mktmpdir("ripr-implicit-return") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          Outcome = Class.new

          def self.compute(events, count)
            return :skipped if count.negative?

            events << count
            Outcome.new if count.positive?
          end

          def self.unstable(events, count)
            events << count
            Outcome.new if count.zero?
          end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_compute
            events = []
            Sample.compute(events, -1)
            100.times { Sample.compute(events, 0) }
            Sample.compute(events, 1)
            assert_equal [0] * 100 + [1], events
          end

          def test_unstable
            counter = "unstable-order"
            run = File.exist?(counter) ? File.read(counter).to_i : 0
            File.write(counter, (run + 1).to_s)
            order = run.even? ? [0, 1] : [1, 0]
            events = []
            order.each { |count| Sample.unstable(events, count) }
            assert_equal order, events
          end
        end
      RUBY

      executable = File.expand_path("../exe/ripr", __dir__)
      arguments = %w[--full --jobs 1 --operators return_nil --reporter agent-v2 --reporter text]
      output, error, status = Open3.capture3(RbConfig.ruby, executable, *arguments, chdir: directory)

      expect(status.exitstatus).to eq(0), error
      json, *text = output.lines
      report = JSON.parse(json)
      schema = JSONSchemer.schema(Pathname.new(File.expand_path("../schema/agent-v2.json", __dir__)))
      expect(schema.validate(report).to_a).to be_empty
      expect(report.fetch("summary")).to include("killed" => 0, "error" => 0, "timeout" => 0, "survived" => 2)
      gaps = report.fetch("gaps").to_h { |gap| [gap.fetch("subject"), gap] }
      gap = gaps.fetch("Sample.compute")
      expect(gap).to include("subject" => "Sample.compute", "operator" => "return_nil", "stage" => "not_revealed")
      expect(gap.fetch("propagation")).to include(
        "test_id" => "SampleTest#test_compute", "call" => 101, "observation" => "implicit_return",
        "original" => ["return_type", "Sample::Outcome"], "mutant" => ["return", ["NilClass", nil]]
      )
      expect(text.join).to include("Sample.compute returned an instance of Sample::Outcome", "(implicit return 101)")
      unstable = gaps.fetch("Sample.unstable")
      expect(unstable.fetch("stage")).to eq("not_detected")
      expect(unstable).not_to have_key("propagation")
    end
  end

  it "retains a stable changed exit when another covering test returns an opaque or unstable value" do
    Dir.mktmpdir("ripr-partial-propagation") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.mixed(value, mode)
            result = value >= 18
            case mode
            when :stable then result
            when :opaque then Object.new
            when :unstable then Process.pid
            end
          end

          def self.hidden(value, mode)
            value >= 18
            case mode
            when :stable then true
            when :opaque then Object.new
            end
          end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_mixed_stable = refute_nil(Sample.mixed(18, :stable))
          def test_mixed_opaque = assert_instance_of(Object, Sample.mixed(18, :opaque))
          def test_mixed_unstable = assert_operator(Sample.mixed(18, :unstable), :>, 0)
          def test_hidden_stable = assert(Sample.hidden(18, :stable))
          def test_hidden_opaque = assert_instance_of(Object, Sample.hidden(18, :opaque))
        end
      RUBY

      executable = File.expand_path("../exe/ripr", __dir__)
      arguments = %w[--full --jobs 1 --operators comparison --reporter agent-v2]
      output, error, status = Open3.capture3(RbConfig.ruby, executable, *arguments, chdir: directory)

      expect(status.exitstatus).to eq(0), error
      report = JSON.parse(output)
      gaps = report.fetch("gaps").to_h { |gap| [gap.fetch("subject"), gap] }
      expect(gaps.transform_values { |gap| gap.fetch("stage") }).to eq(
        "Sample.mixed" => "not_revealed", "Sample.hidden" => "not_detected"
      )
      expect(gaps.fetch("Sample.mixed").fetch("propagation")).to eq(
        "test_id" => "SampleTest#test_mixed_stable", "call" => 1,
        "original" => ["return", ["TrueClass", true]], "mutant" => ["return", ["FalseClass", false]]
      )
      expect(report.fetch("summary")).to include("killed" => 0, "not_revealed" => 1, "not_detected" => 1)
    end
  end

  it "classifies repeatable exits and leaves opaque or unstable exits undiagnosed" do
    Dir.mktmpdir("ripr-propagation") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.hidden(value)
            value >= 18
            true
          end

          def self.visible(value)
            value >= 18
          end

          def self.opaque(value)
            value >= 18
            Object.new
          end

          def self.unstable(value)
            value >= 18
            Process.pid
          end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_hidden = assert(Sample.hidden(18))
          def test_visible = refute_nil(Sample.visible(18))
          def test_opaque = assert_instance_of(Object, Sample.opaque(18))
          def test_unstable = assert_operator(Sample.unstable(18), :>, 0)
        end
      RUBY

      executable = File.expand_path("../exe/ripr", __dir__)
      arguments = %w[--full --jobs 1 --operators comparison --profile --reporter agent --reporter json]
      output, error, status = Open3.capture3(RbConfig.ruby, executable, *arguments, chdir: directory)
      expect(status.exitstatus).to eq(0), error
      snapshot = JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json")))
      results = snapshot.fetch("mutants").values.to_h { |mutant| [mutant.fetch("subject"), mutant] }
      expect(results.transform_values { |mutant| mutant.fetch("status") }).to eq(
        "Sample.hidden" => "not_propagated", "Sample.visible" => "not_revealed",
        "Sample.opaque" => "not_detected", "Sample.unstable" => "not_detected"
      )
      expect(results.fetch("Sample.visible").fetch("propagation")).to include(
        "test_id" => "SampleTest#test_visible", "call" => 1,
        "original" => ["return", ["TrueClass", true]], "mutant" => ["return", ["FalseClass", false]]
      )

      legacy = JSON.parse(output)
      expect(legacy.fetch("schema")).to eq("ripr.agent/v1")
      expect(legacy.fetch("summary")).to include("not_detected" => 4, "survived" => 4)
      expect(legacy.fetch("gaps").map { |gap| gap.fetch("kind") }).to all(eq("not_detected"))
      detailed = legacy.fetch("gaps").find { |gap| gap["subject"] == "Sample.visible" }
      expect(detailed).to include("stage" => "not_revealed", "propagation" => results.fetch("Sample.visible").fetch("propagation"))

      mte = JSON.parse(File.binread(File.join(directory, ".ripr/report/mutation.json")))
      reasons = mte.fetch("files").fetch("lib/sample.rb").fetch("mutants").map { |mutant| mutant.fetch("statusReason") }
      expect(reasons).to include("not_propagated", a_string_matching(/not_revealed.*returned true → returned false/))

      profile = JSON.parse(File.read(File.join(directory, ".ripr/report/profile.json")))
      expect(profile.fetch("diagnosis")).to include("attempted" => 10, "tests_run" => 10)

      text, error, status = Open3.capture3(RbConfig.ruby, executable, "--jobs", "1", "--operators", "comparison", chdir: directory)
      expect(status.exitstatus).to eq(0), error
      expect(text.force_encoding(Encoding::UTF_8)).to include(
        "Reused 4", "not propagated", "not revealed", "returned true → returned false in test/sample_test.rb:"
      )
    end
  end

  it "keeps an earlier complete test when a later test exceeds the call budget" do
    Dir.mktmpdir("ripr-bounded-exits") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.visible(value)
            value >= 18
          end

          def self.unobserved(value)
            value >= 18
          end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_a_short
            refute_nil(Sample.visible(18))
            refute_nil(Sample.unobserved(19))
          end

          def test_z_long
            sleep 0.1
            33.times do
              refute_nil(Sample.visible(19))
              refute_nil(Sample.unobserved(18))
            end
          end
        end
      RUBY

      executable = File.expand_path("../exe/ripr", __dir__)
      output, error, status = Open3.capture3(RbConfig.ruby, executable, "--full", "--jobs", "1",
                                             "--operators", "comparison", "--reporter", "agent-v2", chdir: directory)
      expect(status.exitstatus).to eq(0), error
      report = JSON.parse(output)
      gaps = report.fetch("gaps").to_h { |gap| [gap.fetch("subject"), gap] }
      expect(gaps.fetch("Sample.visible")).to include("stage" => "not_revealed")
      expect(gaps.fetch("Sample.visible").fetch("propagation")).to include(
        "test_id" => "SampleTest#test_a_short", "call" => 1,
        "original" => ["return", ["TrueClass", true]], "mutant" => ["return", ["FalseClass", false]]
      )
      expect(gaps.fetch("Sample.unobserved")).to include("stage" => "not_revealed")
      expect(gaps.fetch("Sample.unobserved").fetch("propagation")).to include(
        "test_id" => "SampleTest#test_z_long", "call" => 1,
        "original" => ["return", ["TrueClass", true]], "mutant" => ["return", ["FalseClass", false]]
      )
      expect(report.fetch("summary")).to include("killed" => 0, "error" => 0, "timeout" => 0, "survived" => 2)
    end
  end
end
