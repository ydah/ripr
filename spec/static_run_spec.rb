# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "ripr/config"

RSpec.describe "static mutation worker" do
  it "returns boot failures with a bounded diagnostic from the worker" do
    require "ripr/engine/runner"

    Dir.mktmpdir("ripr-static-boot") do |directory|
      Dir.chdir(directory) do
        FileUtils.mkdir_p("lib")
        File.write("lib/sample.rb", "module Sample; READY = true; end\n")
        File.write("boot.rb", <<~RUBY)
          require_relative "lib/sample"
          unless Sample::READY
            abort "cannot boot fixture\nload failure\nmissing dependency\nboot stopped\nadditional diagnostic"
          end
        RUBY
        paths = ["lib/sample.rb"]
        config = Ripr::Config.load({ boot: "boot.rb", static: true, operators: ["boolean_literal"] })
        mutant = Ripr::Engine::Runner.new(config, paths).plan.find(&:static)
        worker = Ripr::Engine::StaticRun.new(config, paths, boot_ms: 0)

        expect(worker.call(mutant.full_id, [])).to eq(
          "status" => "error",
          "error" => "static worker failed to boot: cannot boot fixture\nload failure\nmissing dependency\nboot stopped"
        )
      end
    end
  end
end
