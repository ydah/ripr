# frozen_string_literal: true

require "fileutils"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "agent diagnosis and triage" do
  let(:root) { File.expand_path("..", __dir__) }

  def agent_report(directory, *options)
    flags = %w[--jobs 1 --reporter agent-v2] + options
    output, error, status = Open3.capture3(RbConfig.ruby, File.join(root, "exe/ripr"), *flags, chdir: directory)
    expect(status).to be_success, error
    report = JSON.parse(output)
    schema = JSONSchemer.schema(Pathname.new(File.join(root, "schema/agent-v2.json")))
    expect(schema.validate(report).to_a).to be_empty
    report
  end

  def git(directory, *arguments)
    _output, error, status = Open3.capture3("git", *arguments, chdir: directory)
    raise error unless status.success?
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
