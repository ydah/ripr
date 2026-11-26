# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "agent diagnosis and triage" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:v2_schema_path) { File.join(root, "schema/agent-v2.json") }

  def ripr(directory, *options)
    output, error, status = Open3.capture3(RbConfig.ruby, File.join(root, "exe/ripr"), "--jobs", "1", *options, chdir: directory)
    expect(status).to be_success, error
    output.force_encoding(Encoding::UTF_8)
  end

  def agent_report(directory, *options)
    flags = %w[--jobs 1 --reporter agent-v2 --reporter agent] + options
    output, error, status = Open3.capture3(RbConfig.ruby, File.join(root, "exe/ripr"), *flags, chdir: directory)
    expect(status).to be_success, error
    reports = output.lines.map { |line| JSON.parse(line) }
    expect(reports.map { |report| report.fetch("schema") }).to eq(%w[ripr.agent/v2 ripr.agent/v1])
    reports.zip([v2_schema_path, File.join(root, "schema/agent-v1.json")]).each do |report, path|
      schema = JSONSchemer.schema(Pathname.new(path))
      expect(schema.validate(report).to_a).to be_empty
    end
    current, legacy = reports
    stages = %w[not_propagated not_revealed]
    summary = current.fetch("summary")
    expected_summary = summary.except(*stages).merge("not_detected" => summary.fetch("not_detected") + summary.values_at(*stages).sum)
    expect(legacy.fetch("summary")).to eq(expected_summary)
    expected_gaps = current.fetch("gaps").to_h do |gap|
      stage = gap.fetch("stage")
      kind = stages.include?(stage) ? "not_detected" : stage
      [gap.fetch("full_id"), [kind, *gap.values_at("suggested_inputs", "propagation")]]
    end
    legacy_gaps = legacy.fetch("gaps").to_h { |gap| [gap.fetch("full_id"), gap.values_at("kind", "suggested_inputs", "propagation")] }
    expect(legacy_gaps).to eq(expected_gaps)
    current
  end

  def git(directory, *arguments)
    _output, error, status = Open3.capture3("git", *arguments, chdir: directory)
    raise error unless status.success?
  end

  it "keeps the published agent v2 schema frozen" do
    fingerprint = "d29d1627b508fb90d59121f021060e5753afa44a6949f43b3af83f56a9b10bcd"
    message = "Keep schema/agent-v2.json as published. Add a new schema version for contract changes."
    expect(Digest::SHA256.file(v2_schema_path).hexdigest).to eq(fingerprint), message
  end

  it "ranks method gaps and weak tests with the native diagnostic stages" do
    Dir.mktmpdir("ripr-triage") do |directory|
      fixture = File.join(root, "test/fixtures/projects/minitest_basic")
      %w[lib test].each { |path| FileUtils.cp_r(File.join(fixture, path), directory) }
      report = agent_report(directory, "--full")
      expect(report.fetch("schema")).to eq("ripr.agent/v2")
      expect(report.fetch("summary")).to include("not_revealed" => 3, "not_propagated" => 2)

      gaps = report.fetch("gaps")
      discount = gaps.find { |gap| gap["subject"] == "Sample.discount" }
      expect(discount).to include("stage" => "not_revealed", "priority" => 2, "action" => "strengthen_assertion")
      expect(discount.fetch("propagation")).to include("test_id" => "SampleTest#test_discount_runs")
      expect(gaps.find { |gap| gap["subject"] == "Sample.unused" }).to include("stage" => "not_reached", "priority" => 2)
      expect(gaps.find { |gap| gap["stage"] == "not_infected" }).to include("priority" => 1, "suggested_inputs" => [[18, 18]])

      card = report.fetch("methods").find { |method| method["subject"] == "Sample.discount" }
      expect(card).to include("file" => "lib/sample.rb", "stages" => { "not_revealed" => 3 }, "first_gap" => discount.fetch("full_id"))
      expect(report.fetch("weak_tests")).to contain_exactly(include("id" => "SampleTest#test_discount_runs", "reached" => 3))

      expect(ripr(directory)).to include(
        "Sample.discount (lib/sample.rb) · 3 not revealed · Start with #{discount.fetch('id')}",
        "SampleTest#test_discount_runs (3 reached)"
      )

      git(directory, "init", "-q")
      git(directory, "add", "lib", "test")
      git(directory, "-c", "user.name=ripr", "-c", "user.email=ripr@example.test", "commit", "-qm", "original")
      source = File.join(directory, "lib/sample.rb")
      File.write(source, File.read(source).sub("0.9", "0.85"))
      edited = agent_report(directory, "--since", "HEAD")
      expect(edited.fetch("gaps")).not_to be_empty
      expect(edited.fetch("gaps")).to all(include("subject" => "Sample.discount", "stage" => "not_revealed", "priority" => 3))
    end
  end

  it "flags possible equivalence only when method exits match across several covering tests" do
    Dir.mktmpdir("ripr-equivalence") do |directory|
      FileUtils.mkdir_p(%w[lib test].map { |path| File.join(directory, path) })
      File.write(File.join(directory, "lib/sample.rb"), <<~RUBY)
        module Sample
          def self.hidden(value)
            value >= 18
            true
          end

          def self.limited(value)
            value >= 18
            true
          end

          def self.visible(value)
            value >= 18
          end
        end
      RUBY
      File.write(File.join(directory, "test/sample_test.rb"), <<~'RUBY')
        require "minitest/autorun"
        require_relative "../lib/sample"

        class SampleTest < Minitest::Test
          [18, 19, 20].each do |age|
            define_method("test_age_#{age}") do
              assert Sample.hidden(age)
              assert Sample.limited(age) unless age == 20
              refute_nil Sample.visible(age)
            end
          end
        end
      RUBY

      arguments = %w[--operators comparison]
      report = agent_report(directory, "--full", "--reporter", "html", *arguments)
      gaps = report.fetch("gaps").to_h { |gap| [gap.fetch("subject"), gap] }
      hint = "Possible equivalent mutation. Observed method exits matched in all 3 covering tests. Review side effects before accepting."
      hidden = gaps.fetch("Sample.hidden")
      expect(hidden).to include("stage" => "not_propagated", "equivalence_suspected" => true, "hint" => hint)
      expect(hidden.fetch("covering_tests").length).to eq(3)
      limited = gaps.fetch("Sample.limited")
      expect(limited).to include("stage" => "not_propagated", "hint" => a_string_including("Try inputs"))
      expect(limited.fetch("covering_tests").length).to eq(2)
      expect(limited).not_to have_key("equivalence_suspected")
      expect(gaps.fetch("Sample.visible")).to include("stage" => "not_revealed")
      expect(gaps.fetch("Sample.visible")).not_to have_key("equivalence_suspected")
      expect(report.fetch("summary")).to include("not_propagated" => 2, "not_revealed" => 1, "survived" => 3, "score" => 0.0)
      expect(File.binread(File.join(directory, ".ripr/report/index.html"))).to include(hint)
      mte = JSON.parse(File.binread(File.join(directory, ".ripr/report/mutation.json")))
      reasons = mte.fetch("files").fetch("lib/sample.rb").fetch("mutants").map { |mutant| mutant.fetch("statusReason") }
      expect(reasons.grep(/Possible equivalent mutation/)).to eq(["not_propagated. #{hint}"])

      expect(ripr(directory, *arguments).scan(hint).length).to eq(1)

      legacy = JSON.parse(ripr(directory, *arguments, "--reporter", "agent"))
      schema = JSONSchemer.schema(Pathname.new(File.join(root, "schema/agent-v1.json")))
      expect(schema.validate(legacy).to_a).to be_empty
      expect(legacy.fetch("gaps").flat_map(&:keys)).not_to include("equivalence_suspected")
      expect(legacy.fetch("gaps").find { |gap| gap["subject"] == "Sample.hidden" }.fetch("hint")).to eq(limited.fetch("hint"))
    end
  end
end
