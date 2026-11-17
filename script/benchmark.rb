# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "ripr"
require "ripr/core/analyzer"
require "ripr/core/instrumenter"
require "ripr/loader"
require "ripr/runtime"
require "ripr/engine/child"

framework, pattern = ARGV
abort "Usage: ruby script/benchmark.rb minitest|rspec TEST_GLOB" unless %w[minitest rspec].include?(framework) && pattern

unless ENV["RIPR_BENCH_MODE"]
  modes = %w[plain instrumented probe].to_h do |mode|
    output, error, status = Open3.capture3({ "RIPR_BENCH_MODE" => mode }, RbConfig.ruby, __FILE__, framework, pattern)
    abort "#{mode}: #{error}\n#{output}" unless status.success?

    [mode, JSON.parse(output)]
  end
  probe = modes.fetch("probe")
  puts JSON.pretty_generate(
    "ruby" => RUBY_DESCRIPTION, "framework" => framework, "tests_pattern" => pattern,
    "modes" => modes, "disabled_overhead" => (modes.fetch("instrumented").fetch("median_ms") / modes.fetch("plain").fetch("median_ms")) - 1,
    "mutants" => probe.fetch("mutants"), "not_reached" => probe.fetch("not_reached"),
    "not_infected" => probe.fetch("not_infected"), "skipped_fraction" => probe.fetch("skipped_fraction")
  )
  exit
end

mode = ENV.fetch("RIPR_BENCH_MODE")
table = {}
mutants = []
warnings = []
code = Dir["lib/**/*.rb"].to_h do |path|
  source = File.read(path)
  analysis = Ripr::Core::Analyzer.call(source, path, operators: ["comparison"])
  warnings.concat(analysis.fetch(:warnings))

  instrumented = Ripr::Core::Instrumenter.call(source, path, analysis.fetch(:sites))
  warnings.concat(instrumented.fetch(:warnings))

  table.merge!(instrumented.fetch(:site_table))
  mutants.concat(analysis.fetch(:mutants).reject { |mutant| mutant[:invalid] || mutant[:accepted] })
  [File.expand_path(path), instrumented.fetch(:code)]
end
mutants.select! { |mutant| table.values.any? { |ids| ids.include?(mutant.fetch(:id)) } }
loader = Ripr::Loader.new(code).install unless mode == "plain"
$LOAD_PATH.unshift(File.expand_path("lib"), File.expand_path("test"), File.expand_path("spec"))
require "ripr/integration/#{framework}"
adapter_class = framework == "minitest" ? Ripr::Integration::Minitest : Ripr::Integration::RSpec
adapter = adapter_class.new(Dir[pattern], seed: 0).load
raise "No tests discovered" if adapter.tests.empty?

snapshots = []
samples = Array.new(5) do
  result = Ripr::Engine::Child.call(timeout_ms: 120_000) do
    Ripr::R.probe = Ripr::Probe.new(table) if mode == "probe"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run = adapter.run
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    run.merge("elapsed_ms" => elapsed, "probe" => Ripr::R.probe&.snapshot)
  end
  raise(result["error"] || result.fetch("failures", []).inspect) unless result["success"]
  raise "No tests executed" if result.fetch("tests").empty?

  snapshots << result["probe"] if mode == "probe"
  result.fetch("elapsed_ms")
end
report = { "samples_ms" => samples, "median_ms" => samples.sort.fetch(2), "tests" => adapter.tests.size, "warnings" => warnings }
if mode == "probe"
  snapshot = snapshots.first
  reached = snapshot.fetch("reach")
  infected = snapshot.fetch("infect")
  unknown = snapshot.fetch("load_reached")
  not_reached = mutants.count do |mutant|
    !unknown.include?(mutant.fetch(:site)) && reached.fetch(mutant.fetch(:site), []).empty?
  end
  not_infected = mutants.count do |mutant|
    !unknown.include?(mutant.fetch(:site)) &&
      !reached.fetch(mutant.fetch(:site), []).empty? && infected.fetch(mutant.fetch(:id), []).empty?
  end
  report.merge!("mutants" => mutants.size, "not_reached" => not_reached, "not_infected" => not_infected,
                "skipped_fraction" => mutants.empty? ? 0.0 : (not_reached + not_infected).fdiv(mutants.size))
end
loader&.uninstall
puts JSON.generate(report)
