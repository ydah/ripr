# frozen_string_literal: true

require "fileutils"
require "json_schemer"
require "open3"
require "tmpdir"
require "stringio"
require "ripr/config"
require "ripr/core/analyzer"
require "ripr/reporters"

RSpec.describe "comparison chain inputs" do
  let(:source) do
    <<~RUBY
      class Sample
        attr_reader :action, :position, :element

        def initialize(action, position, element)
          @action, @position, @element = action, position, element
        end

        def ==(other)
          action == other.action && position == other.position && element == other.element
        end

        def <=>(other)
          r = action <=> other.action
          r = position <=> other.position if r.zero?
          r = element <=> other.element if r.zero?
          r
        end
      end
    RUBY
  end

  def run_report(directory, *flags)
    executable = File.expand_path("../exe/ripr", __dir__)
    args = [RbConfig.ruby, executable, "--full", "--jobs", "1", *flags, "lib/sample.rb"]
    output, error, status = Open3.capture3(*args, chdir: directory)
    expect(status).to be_success, error
    output
  end

  def report_for(code = source, samples: [[0, 0], [2, 2]], report_source: code)
    analysis = Ripr::Core::Analyzer.call(code, "lib/sample.rb")
    records = JSON.parse(JSON.generate(analysis.fetch(:mutants))).map do |mutant|
      mutant.merge("status" => mutant.fetch("subject").end_with?("#<=>") ? "not_reached" : "killed",
                   "observed" => mutant.fetch("original") == "position == other.position" ? samples : [], "covering_tests" => [])
    end
    yield records if block_given?
    context = Data.define(:sources, :static, :framework, :metrics, :changed_source_lines, :public_subjects)
                  .new({ "lib/sample.rb" => report_source }, 0, "minitest", { "reused" => 0, "baseline_tests_run" => 1 }, {}, {})
    output = StringIO.new
    Ripr::Reporters.write(records, context, Ripr::Config.load({ reporters: ["agent-v2"] }), stdout: output)
    JSON.parse(output.string).fetch("gaps")
  end

  it "asserts the sign implied by the sampled native Integer values" do
    gaps = report_for(samples: [[2, 2], [0, 0]]).select { |gap| gap.key?("comparison_inputs") }
    expect(gaps.size).to eq(4)
    gaps.each do |gap|
      expect(gap.fetch("comparison_inputs").fetch("values")).to eq([2, 0])
      expect(gap.fetch("hint")).to include("fixture instances", "(left <=> right) == 1", "(right <=> left) == -1")
    end
  end

  it "requires native Integer evidence with two distinct values" do
    [[], [[0, 0]], [%w[0 0], %w[2 2]], [[0.0, 0.0], [2.0, 2.0]], [[nil, nil], [true, false]]].each do |samples|
      expect(report_for(samples: samples).flat_map(&:keys)).not_to include("comparison_inputs")
    end
  end

  it "requires a strict zero-guarded comparison chain" do
    [
      source.sub("if r.zero?", "unless r.zero?"),
      source.sub("if r.zero?", "if !r.zero?"),
      source.sub("if r.zero?", "if r.zero? || true"),
      source.sub("r = position", "s = position"),
      source.sub("    r\n", "    r + 1\n"),
      source.sub("def <=>(other)", "def <=>(other = nil)"),
      source.sub("r = position <=> other.position", "r = position <=> other&.position"),
      source.sub("r = action <=>", "r = [action] <=>")
    ].each do |code|
      expect(report_for(code).flat_map(&:keys)).not_to include("comparison_inputs")
    end
  end

  it "requires the current source and exact equality record identity and spans" do
    expect(report_for(report_source: "# shifted\n#{source}").flat_map(&:keys)).not_to include("comparison_inputs")
    expect(report_for(report_source: "class Sample; def broken(").flat_map(&:keys)).not_to include("comparison_inputs")
    %w[id full_id subject original mutated method_hash start_offset end_offset location].each do |key|
      gaps = report_for do |records|
        record = records.find { |mutant| mutant.fetch("original") == "position == other.position" }
        record[key] = nil
      end
      expect(gaps.flat_map(&:keys)).not_to include("comparison_inputs")
    end
    expect(report_for do |records|
      records.reject! { |mutant| mutant.fetch("subject") == "Sample#==" }
    end.flat_map(&:keys)).not_to include("comparison_inputs")
  end

  it "requires the target's current identity and span without changing other targets" do
    %w[id subject original mutated method_hash start_offset end_offset location].each do |key|
      damaged = nil
      gaps = report_for do |records|
        record = records.find { |mutant| mutant.fetch("original") == "r = position <=> other.position if r.zero?" }
        damaged = record.fetch("full_id")
        record[key] = case key
                      when "subject" then "Other#<=>"
                      when "location" then record.fetch(key).merge("column" => 1)
                      end
      end
      expect(gaps.find { |gap| gap.fetch("full_id") == damaged }).not_to have_key("comparison_inputs")
      expect(gaps.count { |gap| gap.key?("comparison_inputs") }).to eq(3)
    end
  end

  it "omits guidance for redefined comparison or equality methods" do
    [
      source.sub("  def <=>(other)", "  def ==(other); position == other.position; end\n  def <=>(other)"),
      source.sub("  def <=>(other)", "  def <=>(other); position <=> other.position; end\n  def <=>(other)")
    ].each do |code|
      expect(report_for(code).flat_map(&:keys)).not_to include("comparison_inputs")
    end
  end

  it "offers independently observed numeric field values for an unreached comparison chain through all reports" do
    Dir.mktmpdir("ripr-comparison-inputs") do |directory|
      %w[lib test].each { |name| FileUtils.mkdir_p(File.join(directory, name)) }
      File.write(File.join(directory, "lib/sample.rb"), source)
      File.write(File.join(directory, "test/sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          def test_equal_fields
            [["a", 0, "left"], ["b", 2, "right"]].each do |fields|
              assert_equal Sample.new(*fields), Sample.new(*fields)
            end
          end
        end
      RUBY
      flags = %w[--reporter agent-v2 --reporter agent --reporter json]
      reports = run_report(directory, *flags).lines.map { |line| JSON.parse(line) }
      gaps = reports.first.fetch("gaps").select { |gap| gap.fetch("subject") == "Sample#<=>" }
      guided, generic = gaps.partition { |gap| gap.key?("comparison_inputs") }
      expect(guided.size).to eq(4)
      inputs = { "left" => "position", "right" => "other.position", "values" => [0, 2],
                 "zero_comparisons" => ["action <=> other.action", "element <=> other.element"] }
      expect(guided).to all(include("stage" => "not_reached", "action" => "add_test", "observed" => [], "comparison_inputs" => inputs))
      expect(generic.map { |gap| gap.fetch("original") }).to contain_exactly("r.zero?", "r = element <=> other.element if r.zero?")
      guided.each do |gap|
        expect(gap.fetch("hint")).to include("position", "action <=> other.action", "element <=> other.element", "zero", "independently",
                                             "Sample#==", "fixture instances", "(left <=> right) == -1", "(right <=> left) == 1")
      end
      expect(reports.last.fetch("gaps").select { |gap| gap.fetch("subject") == "Sample#<=>" }
                    .map { |gap| gap.fetch("id") })
        .to eq(gaps.map { |gap| gap.fetch("id") })
      expect(reports.last.fetch("gaps").flat_map(&:keys)).not_to include("comparison_inputs", "suggested_inputs")
      legacy = JSON.parse(run_report(directory, "--reporter", "agent"))
      comparison_gaps = ->(report) { report.fetch("gaps").select { |gap| gap.fetch("subject") == "Sample#<=>" } }
      expect(comparison_gaps.call(reports.last)).to eq(comparison_gaps.call(legacy))
      reports.zip(%w[agent-v2 agent-v1]).each do |report, name|
        schema = JSONSchemer.schema(Pathname.new(File.expand_path("../schema/#{name}.json", __dir__)))
        expect(schema.validate(report).to_a).to be_empty
      end

      output = run_report(directory, "--reporter", "text", "--reporter", "json")
      expect(output).to include("position <=> other.position", "[0,2]", "return zero", "independently")
      mte = JSON.parse(File.read(File.join(directory, ".ripr/report/mutation.json"), encoding: "UTF-8"))
      by_id = mte.fetch("files").fetch("lib/sample.rb").fetch("mutants").to_h { |mutant| [mutant.fetch("id"), mutant] }
      guided.each do |gap|
        expect(by_id.fetch(gap.fetch("id"))).to include("status" => "NoCoverage")
        expect(by_id.fetch(gap.fetch("id")).fetch("statusReason")).to include("[0,2]", "position <=> other.position", "return zero",
                                                                              "independently")
      end
      cached = JSON.parse(File.read(File.join(directory, ".ripr/snapshot.json"))).fetch("mutants").values
      expect(cached.flat_map(&:keys)).not_to include("comparison_inputs", "suggested_inputs")

      partial = JSON.parse(run_report(directory, "--reporter", "agent-v2", "--only", guided.first.fetch("id")))
      expect(partial.fetch("gaps").flat_map(&:keys)).not_to include("comparison_inputs", "suggested_inputs")
      no_samples = JSON.parse(run_report(directory, "--reporter", "agent-v2", "--no-samples"))
      expect(no_samples.fetch("gaps").select { |gap| gap.fetch("subject") == "Sample#<=>" }.flat_map(&:keys))
        .not_to include("comparison_inputs", "suggested_inputs")
    end
  end
end
