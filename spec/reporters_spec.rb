# frozen_string_literal: true

require "ripr/reporters"
require "ripr/config"
require "json_schemer"

RSpec.describe Ripr::Reporters do
  let(:mutant) do
    { "id" => "a123456789", "full_id" => "lib/a.rb::A#b::body::comparison::>", "subject" => "A#b",
      "operator" => "comparison", "original" => "x >= 18", "mutated" => "x > 18", "status" => "not_infected",
      "observed" => [[20, 18]], "covering_tests" => [],
      "location" => { "file" => "lib/a.rb", "line" => 2, "column" => 3, "end_line" => 2, "end_column" => 10 } }
  end

  it "emits Ruby language metadata required by the mutation report schema" do
    report = described_class.mte([mutant], { "lib/a.rb" => "x >= 18" }, { "high" => 80, "low" => 60 })
    expect(report.fetch("files").fetch("lib/a.rb").fetch("language")).to eq("ruby")
  end

  it "includes the acceptance reason in ignored mutation reports" do
    accepted = mutant.merge("status" => "accepted", "accepted" => "Only strictly positive inputs are supported")
    report = described_class.mte([accepted], { "lib/a.rb" => "" }, {})
    result = report.fetch("files").fetch("lib/a.rb").fetch("mutants").first
    expect(result.fetch("statusReason")).to eq(accepted.fetch("accepted"))
  end

  it "escapes source code and file paths in HTML and workflow annotations" do
    report = described_class.mte([mutant.merge("mutated" => "<script>alert(1)</script>")], { "lib/a.rb" => "" }, {})
    html = described_class.html(report)
    expect(html).not_to include("<script>alert")
    expect(html).to include("&lt;script&gt;")
    expect(described_class.annotation("a,b:c%\r\n", property: true)).to eq("a%2Cb%3Ac%25%0D%0A")
  end

  it "embeds report data safely for the official viewer with an offline fallback" do
    report = described_class.mte([mutant], { "lib/a.rb" => "</script><script>alert(1)</script>" }, {})
    html = described_class.html(report)
    expect(html).to include("mutation-test-report-app", "mutation-testing-elements@3.9.0", "integrity=", "fallback-report")
    data = html.match(%r{<script type="application/json" id="mutation-report">(.*?)</script>}m)[1]
    expect(JSON.parse(data)).to eq(report)
    expect(data).not_to include("</script>")
  end

  it "offers observed operands and precise rerun commands to agents" do
    report = described_class.agent([mutant], {})
    gap = report.fetch("gaps").first
    expect(gap.fetch("hint")).to include("[[20,18]]")
    expect(gap.fetch("action")).to eq("add_input")
    expect(gap.fetch("rerun")).to eq("ripr --only a123456789")
  end

  it "validates the agent protocol and rejects contradictory actions" do
    schema = JSONSchemer.schema(JSON.parse(File.read(File.expand_path("../schema/agent-v1.json", __dir__))))
    report = described_class.agent([mutant], { "since" => nil, "scope" => "node", "framework" => "minitest" })
    expect(schema.validate(report).to_a).to be_empty
    report.fetch("gaps").first["action"] = "add_test"
    expect(schema.valid?(report)).to be(false)
  end
end
