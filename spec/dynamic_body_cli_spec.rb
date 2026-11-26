# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "dynamic mutation bodies" do
  let(:executable) { File.expand_path("../exe/ripr", __dir__) }

  def run(directory, *args)
    output, error, status = Open3.capture3(RbConfig.ruby, executable, *args, chdir: directory)
    expect(status).to be_success, error
    [output, error]
  end

  it "switches define_method, lambda and proc bodies at invocation time" do
    Dir.mktmpdir("ripr-dynamic-bodies") do |directory|
      FileUtils.mkdir_p([File.join(directory, "lib"), File.join(directory, "test")])
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        class Sample
          factor = 2
          define_method(:price) { |base: 4| base + factor }
          FIRST = ->(base: 4) { base + factor }
          SECOND = ->(base) { base + factor }
          THIRD = proc { |base| base + factor }
          FOURTH = lambda { |base| base + factor }
          FIFTH = Proc.new { |base| base + factor }
          UNASSERTED = ->(base) { base + factor }

          def self.install(increment)
            define_method(:tax) { |base: 4| base + increment }
          end
          install(factor)
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"
        class SampleTest < Minitest::Test
          def test_deferred_bodies
            sample = Sample.new
            assert_equal 6, sample.price
            assert_equal 8, sample.price(base: 6)
            assert_equal 6, Sample::FIRST.call
            assert_equal 6, Sample::SECOND.call(4)
            assert_equal 6, Sample::THIRD.call(4)
            assert_equal 6, Sample::FOURTH.call(4)
            assert_equal 6, Sample::FIFTH.call(4)
            assert_equal 6, sample.tax
            Sample::UNASSERTED.call(4)
          end
        end
      RUBY
      output, = run(directory, "--full", "--jobs", "1", "--operators", "arithmetic", "--call-graph-reuse", "--reporter", "agent")
      expect(JSON.parse(output).fetch("summary").fetch("killed")).to eq(7)
      path = File.join(directory, ".ripr/snapshot.json")
      mutants = JSON.parse(File.read(path)).fetch("mutants").values
      expect(mutants.map { |mutant| mutant.fetch("subject") }).to contain_exactly(
        "Sample#price<define_method>", "Sample#<lambda>", "Sample#<lambda>[2]", "Sample#<proc>",
        "Sample#<lambda>[3]", "Sample#<lambda>[4]", "Sample#<proc>[2]", "Sample#tax<define_method>"
      )
      expect(mutants).to all(include("load_reached" => false))
      expect(mutants.reject { |mutant| mutant["subject"] == "Sample#<lambda>[4]" })
        .to all(include("status" => "killed", "killed_by" => "SampleTest#test_deferred_bodies"))
      expect(mutants.find { |mutant| mutant["subject"] == "Sample#<lambda>[4]" }).to include("status" => "not_detected")
      expect(mutants.any? { |mutant| mutant["static"] }).to be(false)
      expect(mutants.map { |mutant| mutant.fetch("id") }.uniq.length).to eq(8)

      source = File.join(directory, "lib/sample.rb")
      File.write(source, File.read(source).sub("factor = 2", "factor = 0x2"))
      output, = run(directory, "--jobs", "1", "--operators", "arithmetic", "--call-graph-reuse", "--reporter", "agent")
      expect(JSON.parse(output).fetch("run").fetch("metrics")).to include("reused" => 0)
      refreshed = JSON.parse(File.read(path)).fetch("mutants").values
      expect(refreshed.map { |mutant| mutant.values_at("id", "method_hash") })
        .to match_array(mutants.map { |mutant| mutant.values_at("id", "method_hash") })
    end
  end

  it "lists skipped sites once each without loading the project" do
    Dir.mktmpdir("ripr-skipped-sites") do |directory|
      FileUtils.mkdir_p([File.join(directory, "lib"), File.join(directory, "test")])
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        TOTAL = 2
        def example(value)
          puts "ignored"
          pinned = 1
          matches = (value in ^pinned)
          defined?(value >= 3)
          value >= 2 # ripr:disable-line comparison -- external boundary
          [1i, matches]
        end
        class << Object.new
          def ignored; 1; end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), "raise 'must not load tests'\n")
      output, error = run(directory, "list", "mutants", "--skipped", "--operators", "integer_literal,comparison,statement_removal")
      lines = output.lines.map(&:chomp)
      expect(lines).to include(
        "lib/sample.rb:1:9 load-time expression requires --static",
        "lib/sample.rb:3:3 statement removal suppressed by arid_callees",
        "lib/sample.rb:4:3 replacement is invalid Ruby",
        "lib/sample.rb:6:12 defined? operand requires its original syntax",
        "lib/sample.rb:7:3 accepted: external boundary",
        "lib/sample.rb:8:4 unsupported instrumentation",
        "lib/sample.rb:10:1 unsupported singleton receiver"
      )
      expect(lines).to eq(lines.uniq)
      expect(error).to be_empty
      expect(File).not_to exist(File.join(directory, ".ripr"))
    end
  end
end
