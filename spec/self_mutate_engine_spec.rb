# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "Engine and runtime self-mutation" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:script) { File.join(root, "script/self_mutate_engine.rb") }

  it "runs known Engine and runtime variants with the same suites as their original sources" do
    output, error, status = Open3.capture3(RbConfig.ruby, script, "--jobs", "2",
                                           "--only", "9b991da16a", "--only", "fca8dc001e", chdir: root)

    expect(status).to be_success, error
    report = JSON.parse(output)
    expect(report.fetch("mutants").map { |result| result.values_at("id", "status") })
      .to contain_exactly(%w[9b991da16a killed], %w[fca8dc001e killed])
    expect(report.fetch("baselines").values).to all(include("status" => "passed"))
  end

  it "distinguishes an example failure, an error loading specs, a crashed process, and a timeout" do
    require_relative "../script/self_mutate_engine"

    Dir.mktmpdir("ripr-self-mutation-fixture") do |directory|
      %w[Gemfile Gemfile.lock ripr.gemspec lib spec/spec_helper.rb].each do |path|
        source = File.join(root, path)
        destination = File.join(directory, path)
        next unless File.exist?(source)

        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp_r(source, destination)
      end
      file = "spec/fixture_spec.rb"
      absolute = File.join(directory, file)
      config = { bundle_path: Bundler.settings[:path] && File.expand_path(Bundler.settings[:path], root), timeout_seconds: 10 }

      File.write(absolute, 'RSpec.describe("fixture") { it("fails") { expect(1).to eq(2) } }')
      failure = SelfMutateEngine.run_specs(directory, [file], **config)
      expect(failure).to include("status" => "killed", "examples" => 1)

      File.write(absolute, 'raise "load error"')
      load_error = SelfMutateEngine.run_specs(directory, [file], **config)
      expect(load_error).to include("status" => "error", "error" => include("load error"))

      File.write(absolute, 'Process.kill("KILL", Process.pid)')
      crash = SelfMutateEngine.run_specs(directory, [file], **config)
      expect(crash).to include("status" => "error", "error" => include("signal"))

      File.write(absolute, "sleep 30")
      timeout = SelfMutateEngine.run_specs(directory, [file], **config, timeout_seconds: 0.5)
      expect(timeout).to include("status" => "timeout")
    end
  end
end
