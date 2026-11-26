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
    fingerprint = "1ee0b7050621532c606511a3ab4c8ff226d6cde97169a874ec09884ef191f038"
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

      text, error, status = Open3.capture3(RbConfig.ruby, File.join(root, "exe/ripr"), "--jobs", "1", chdir: directory)
      expect(status).to be_success, error
      expect(text.force_encoding(Encoding::UTF_8)).to include(
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
end
