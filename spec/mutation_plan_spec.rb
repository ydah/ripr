# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "ripr/config"

RSpec.describe "mutation planning" do
  it "normalizes overlapping inputs, excludes generated sources, and reuses a completed plan" do
    require "ripr/engine/runner"

    Dir.mktmpdir("ripr-plan-inputs") do |directory|
      Dir.chdir(directory) do
        FileUtils.mkdir_p(["lib/generated", "lib/empty.rb"])
        File.write("lib/threshold.rb", "def threshold?(value); value >= 2; end\n")
        File.write("lib/generated/ignored.rb", "def ignored?(value); value >= 3; end\n")
        File.write("lib/notes.txt", "this is not Ruby source")
        config = Ripr::Config.load({ operators: ["comparison"], exclude: ["lib/generated/*"], dry_run: true })
        runner = Ripr::Engine::Runner.new(config, ["lib/**/*", File.expand_path("lib/threshold.rb")])
        definitions = runner.plan

        expect(definitions.map { |definition| definition.location.file }).to eq(["lib/threshold.rb"])
        expect(runner.sources.keys).to eq(["lib/threshold.rb"])
        expect(runner.metrics).to eq("baseline_reused" => false, "baseline_tests_run" => 0, "reused" => 0)
        File.write("lib/threshold.rb", "def threshold?(value); value <= 8; end\n")
        expect(runner.plan).to eq(definitions)
        expect(runner.call).to eq(definitions.map { |definition| definition.to_record.merge("status" => "planned") })
      end
    end
  end

  it "keeps mutation definitions immutable and exports the existing record fields" do
    require "ripr/engine/runner"

    Dir.mktmpdir("ripr-mutation-plan") do |directory|
      Dir.chdir(directory) do
        File.write("threshold.rb", "def threshold?(value); value >= 2; end\n")
        config = Ripr::Config.load({ operators: ["comparison"] })
        definitions = Ripr::Engine::Runner.new(config, ["threshold.rb"]).plan
        expect(definitions).to be_frozen

        definition = definitions.fetch(0)
        expect(definition).to be_a(Data)
        expect(definition.location).to be_a(Data)
        expect(definition.original).to be_frozen
        expect(definition.fixed_operands).to be_frozen
        expect(definition.to_record).to include(
          "id" => definition.id, "subject" => "Object#threshold?", "original" => "value >= 2",
          "mutated" => "value > 2", "accepted" => nil, "fixed_operands" => [false, true],
          "location" => include("file" => "threshold.rb", "line" => 1, "end_line" => 1)
        )
        expect(definition.to_record.keys).not_to include("static", "invalid", "invalid_reason")
      end
    end
  end
end
