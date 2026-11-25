# frozen_string_literal: true

require "json"
require "tmpdir"
require "ripr/reporters/html"

RSpec.describe Ripr::Reporters::HTML do
  let(:script_text) { "</script><script>window.reportPayload = true</script>" }

  let(:report) do
    location = { "start" => { "line" => 1, "column" => 1 }, "end" => { "line" => 1, "column" => 2 } }
    mutants = %w[one two].map do |id|
      { "id" => id, "mutatorName" => "comparison", "status" => "Survived", "location" => location,
        "statusReason" => script_text, "replacement" => script_text }
    end
    { "schemaVersion" => "2", "thresholds" => { "high" => 80, "low" => 60 },
      "files" => { "lib/<quoted>.rb" => { "language" => "ruby", "source" => script_text, "mutants" => mutants } } }
  end

  let(:stages) { { "one" => "not_propagated", "two" => "not_revealed" } }

  it "writes a standalone report with the pinned viewer, stage controls, and an escaped table" do
    Dir.mktmpdir("ripr-html") do |directory|
      path = File.join(directory, "report")
      described_class.write(report, path, stages: stages)
      expect(Dir.children(path)).to eq(["index.html"])
      html = File.read(File.join(path, "index.html"), encoding: "UTF-8")
      expect(html).to include('data-viewer-version="3.9.0"', "Apache License", "fuzziersort 4.0.2", 'id="fallback-report"')
      expect(html).to include('value="not_propagated"', 'value="not_revealed"')
      expect(html).to include('data-stage="not_propagated"', 'data-stage="not_revealed"', "lib/&lt;quoted&gt;.rb")
      expect(html).not_to include(script_text, "cdn.jsdelivr.net")
      data = html[%r{<script type="application/json" id="mutation-report">(.*?)</script>}m, 1]
      expect(JSON.parse(data)).to eq(report)
    end
  end
end
