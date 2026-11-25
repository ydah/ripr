# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "method-exit mutation diagnosis" do
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
end
