# frozen_string_literal: true

require_relative "../script/compare_verdicts"

RSpec.describe CompareVerdicts do
  it "matches a token edit to a full expression replacement at the same byte location" do
    file = "lib/policy.rb"
    expression = described_class.edit(file, 30, "é >= limit", "é > limit")
    token = described_class.edit(file, 33, ">=", ">")

    expect(expression).to eq(token)
    expect(expression).not_to eq(described_class.edit(file, 34, ">=", ">"))
    expect(expression).not_to eq(described_class.edit(file, 33, ">=", "=="))
  end

  it "gives each tool a separate copy of the prepared Rails test database" do
    Dir.mktmpdir do |project|
      File.write(File.join(project, "source.rb"), "nil\n")
      File.write(File.join(project, "app_test.rb"), "nil\n")
      File.write(File.join(project, "test.sqlite3"), "prepared")
      executions = []
      %i[ripr mutineer].each do |tool|
        allow(described_class).to receive(tool) do |directory, *, **options|
          expect(options).to include(rails: true, operators: ["comparison"])
          database = File.join(directory, "test.sqlite3")
          expect(File.read(database)).to eq("prepared")
          File.write(database, tool.to_s)
          executions << directory
          []
        end
      end

      described_class.run(project, "source.rb", "minitest", ["app_test.rb"], "/fake", rails: true, operators: ["comparison"])

      expect(executions.uniq.size).to eq(2)
      expect(File.read(File.join(project, "test.sqlite3"))).to eq("prepared")
    end
  end
end
