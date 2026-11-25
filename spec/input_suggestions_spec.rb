# frozen_string_literal: true

require "fileutils"
require "json_schemer"
require "open3"
require "tmpdir"
require "ripr/core/analyzer"
require "ripr/reporters"
require "ripr/runtime"

RSpec.describe "suggested mutation inputs" do
  def gap(operator, observations, status: "not_infected")
    source = "def calculate(left, right); left #{operator} right; end"
    analysis = Ripr::Core::Analyzer.call(source, "lib/sample.rb", operators: %w[comparison arithmetic], arid_callees: [])
    mutant = analysis.fetch(:mutants).first
    mutant = JSON.parse(JSON.generate(mutant)).merge("observed" => observations, "status" => status)
    Ripr::Reporters.agent([mutant], {}).fetch("gaps").first
  end

  {
    ">=" => [">", [20, 18]], ">" => [">=", [20, 18]], "<=" => ["<", [20, 18]], "<" => ["<=", [20, 18]],
    "==" => ["!=", [20, 18]], "!=" => ["==", [20, 18]], "+" => ["-", [20, 0]], "-" => ["+", [20, 0]],
    "*" => ["/", [20, 1]], "/" => ["*", [20, -1]], "%" => ["*", [0, 2]]
  }.each do |original, (replacement, observed)|
    it "suggests operands that distinguish #{original} from #{replacement} while retaining an observed operand" do
      candidates = gap(original, [observed]).fetch("suggested_inputs")
      expect(candidates).not_to be_empty
      candidates.each do |left, right|
        expect(left == observed.first || right == observed.last).to be(true)
        expect(Ripr::Value.same?(left.public_send(original, right), left.public_send(replacement, right))).to be(false)
      end
    end
  end

  it "uses the observed comparison boundary and explains the sampled miss" do
    result = gap(">=", [[20, 18], [10, 18]])
    expect(result.fetch("suggested_inputs")).to eq([[18, 18]])
    expect(result.fetch("hint")).to include("No sampled pair had equal operands.")
  end

  it "retains the left operand when its type cannot represent the observed right operand" do
    expect(gap(">=", [[20, 18.5]]).fetch("suggested_inputs")).to eq([[20, 20.0]])
  end

  it "checks arithmetic suggestions against Ruby rounding" do
    candidates = gap("+", [[1e20, 0.0]]).fetch("suggested_inputs")
    expect(candidates).not_to be_empty
    candidates.each do |left, right|
      expect(left).to be_a(Float)
      expect(right).to be_a(Float)
      expect(left + right).not_to eq(left - right)
    end
  end

  it "finds a defined arithmetic example when neither sampled operand alone permits a change" do
    candidates = gap("/", [[0, 1]]).fetch("suggested_inputs")
    expect(candidates).not_to be_empty
    candidates.each { |left, right| expect(left / right).not_to eq(left * right) }
  end

  it "keeps the generic guidance when samples do not preserve operand types or the gap is unrelated" do
    expect(gap(">=", [["1/2", "3/4"]])).not_to have_key("suggested_inputs")
    expect(gap(">=", [])).not_to have_key("suggested_inputs")
    expect(gap(">=", [[20, 18]], status: "not_reached")).not_to have_key("suggested_inputs")
  end

  it "keeps literal operands fixed while reporting input suggestions through the CLI" do
    Dir.mktmpdir("ripr-literal-inputs") do |directory|
      %w[lib test].each { |name| FileUtils.mkdir_p(File.join(directory, name)) }
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.identity(value)
            value + ((0))
          end

          def self.from_zero(value)
            0 + value
          end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_arithmetic
            assert_equal 20, Sample.identity(20)
            assert_equal 0, Sample.from_zero(0)
          end
        end
      RUBY
      executable = File.expand_path("../exe/ripr", __dir__)
      args = [RbConfig.ruby, executable, "--operators", "arithmetic", "--reporter", "agent"]
      stdout, stderr, status = Open3.capture3(*args, chdir: directory)
      expect(status).to be_success, stderr
      gaps = JSON.parse(stdout).fetch("gaps").to_h { |result| [result.fetch("subject"), result] }
      identity = gaps.fetch("Sample.identity")
      expect(identity.fetch("kind")).to eq("not_infected")
      expect(identity).not_to have_key("suggested_inputs")
      expect(gaps.fetch("Sample.from_zero").fetch("suggested_inputs")).to eq([[0, 1]])
    end
  end

  it "reports the same suggestions when rerunning results from an older snapshot" do
    Dir.mktmpdir("ripr-suggested-inputs") do |directory|
      fixture = File.expand_path("../test/fixtures/projects/minitest_basic", __dir__)
      FileUtils.cp_r(%w[lib test].map { |path| File.join(fixture, path) }, directory)
      executable = File.expand_path("../exe/ripr", __dir__)
      args = [RbConfig.ruby, executable, "--operators", "comparison"]
      stdout, stderr, status = Open3.capture3(*args, "--reporter", "agent", chdir: directory)
      expect(status).to be_success, stderr
      fresh = JSON.parse(stdout)
      expect(fresh.fetch("gaps").first.fetch("suggested_inputs")).to eq([[18, 18]])
      schema = JSONSchemer.schema(JSON.parse(File.read(File.expand_path("../schema/agent-v1.json", __dir__))))
      expect(schema.validate(fresh).to_a).to be_empty

      snapshot = File.join(directory, ".ripr/snapshot.json")
      previous = JSON.parse(File.read(snapshot))
      previous.fetch("mutants").each_value do |mutant|
        mutant.delete("original_operator")
        mutant.delete("fixed_operands")
      end
      File.write(snapshot, JSON.generate(previous))
      stdout, stderr, status = Open3.capture3(*args, "--reporter", "agent", chdir: directory)
      expect(status).to be_success, stderr
      warm = JSON.parse(stdout)
      expect(warm.dig("run", "metrics", "reused")).to be_positive
      expect(warm.fetch("gaps")).to eq(fresh.fetch("gaps"))

      stdout, stderr, status = Open3.capture3(*args, "--reporter", "text", "--reporter", "json", chdir: directory)
      expect(status).to be_success, stderr
      expect(stdout).to include("suggested inputs: [[18,18]]", "No sampled pair had equal operands.")
      report = JSON.parse(File.read(File.join(directory, ".ripr/report/mutation.json")))
      first = report.fetch("files").fetch("lib/sample.rb").fetch("mutants").first
      expect(first.fetch("statusReason")).to include("[[18,18]]", "No sampled pair had equal operands.")
    end
  end
end
