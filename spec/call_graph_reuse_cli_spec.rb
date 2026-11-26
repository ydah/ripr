# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "call-graph reuse" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }

  it "retains independent trial dependencies while rerunning callers of an edited method" do
    Dir.mktmpdir("ripr-trial-dependencies") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      source = File.join(directory, "lib/sample.rb")
      File.write(source, <<~RUBY)
        module Sample
          def self.threshold(age)
            age >= 18
          end

          def self.caller(age)
            threshold(age) && age >= 18
          end

          def self.independent(age)
            age >= 5
          end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_caller = assert(Sample.caller(18))
          def test_independent = assert(Sample.independent(5))
        end
      RUBY
      command = [RbConfig.ruby, executable, "--jobs", "1", "--operators", "comparison", "--reporter", "agent", "--call-graph-reuse"]
      output, error, status = Open3.capture3(*command, chdir: directory)
      expect(status).to be_success, error
      expect(JSON.parse(output).fetch("summary")).to include("killed" => 3, "error" => 0)

      File.write(source, File.read(source).sub("age >= 18", "age >= 17"))
      output, error, status = Open3.capture3(*command, chdir: directory)
      expect(status).to be_success, error
      report = JSON.parse(output)
      expect(report.dig("run", "metrics")).to include("reused" => 1, "baseline_tests_run" => 2)
      expect(report.fetch("summary")).to include("killed" => 2, "not_infected" => 1, "error" => 0)
      snapshot = JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json")))
      reused = snapshot.fetch("mutants").values.select { |record| record["reused"] }
      expect(reused.map { |record| record.fetch("subject") }).to eq(["Sample.independent"])
    end
  end
end
