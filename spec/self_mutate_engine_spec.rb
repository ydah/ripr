# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "Engine and runtime self-mutation" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:script) { File.join(root, "script/self_mutate_engine.rb") }

  it "uses the reach-map specifications for reach mutations in Runner" do
    require_relative "../script/self_mutate_engine"

    location = { file: "lib/ripr/engine/runner.rb" }
    %w[record_reach_map reach_baseline prepare_test_file_loading prepare_reach_selection].each do |method|
      mutant = { location: location, subject: "Ripr::Engine::Runner##{method}" }
      expect(SelfMutateEngine.suite(mutant)).to eq(%w[spec/reach_map_cli_spec.rb spec/reach_selection_cli_spec.rb])
    end
    mutant = { location: location, subject: "Ripr::Engine::Runner#load_tests" }
    expect(SelfMutateEngine.suite(mutant)).to include("spec/cache_cli_spec.rb", "spec/profile_spec.rb")
  end

  it "runs known Engine and runtime variants with the same suites as their original sources" do
    options = ["--jobs", "2", "--only", "9b991da16a", "--only", "fca8dc001e"]
    output, error, status = Open3.capture3(RbConfig.ruby, script, *options, chdir: root)

    expect(status).to be_success, error
    report = JSON.parse(output)
    expect(report.fetch("mutants").map { |result| result.values_at("id", "status") })
      .to contain_exactly(%w[9b991da16a killed], %w[fca8dc001e killed])
    expect(report.fetch("baselines").values).to all(include("status" => "passed"))

    Dir.mktmpdir("ripr-engine-shards") do |directory|
      paths = (1..2).map do |index|
        output, error, status = Open3.capture3(RbConfig.ruby, script, *options, "--shard", "#{index}/2", chdir: root)
        expect(status).to be_success, error
        expect(JSON.parse(output).fetch("mutants").size).to eq(1)
        path = File.join(directory, "#{index}.json")
        File.write(path, output)
        path
      end

      merge = ->(files) { Open3.capture3(RbConfig.ruby, script, *options, "--merge", *files, chdir: root) }
      output, error, status = merge.call(paths.reverse)
      expect(status).to be_success, error
      merged = JSON.parse(output)
      expect(merged.fetch("summary")).to eq(report.fetch("summary"))
      expect(merged.fetch("mutants").map { |result| result.values_at("full_id", "status") })
        .to eq(report.fetch("mutants").map { |result| result.values_at("full_id", "status") })
      expect(merged.fetch("baselines").keys).to match_array(report.fetch("baselines").keys)

      [paths.take(1), [paths.first, paths.first], [*paths, paths.first]].each do |incomplete|
        output, error, status = merge.call(incomplete)
        expect(status).not_to be_success
        expect(output).to be_empty
        expect(error).to include("mutation inventory")
      end

      stale = JSON.parse(File.read(paths.first))
      stale.fetch("mutants").first["original"] = "older source"
      File.write(paths.first, JSON.generate(stale))
      output, error, status = merge.call(paths)
      expect(status).not_to be_success
      expect(output).to be_empty
      expect(error).to include("mutation inventory")
    end
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
