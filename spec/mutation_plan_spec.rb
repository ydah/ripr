# frozen_string_literal: true

require "tmpdir"
require "ripr/config"
require "ripr/engine/runner"

RSpec.describe "mutation planning" do
  it "keeps mutation definitions immutable and exports the existing record fields" do
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
