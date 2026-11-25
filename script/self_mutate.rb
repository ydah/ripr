# frozen_string_literal: true

require "English"
require "json"
require "rbconfig"
require "shellwords"
require "tmpdir"
require_relative "../lib/ripr/core/analyzer"
require_relative "../lib/ripr/core/instrumenter"

abort "Usage: ruby script/self_mutate.rb [--check]" unless [[], ["--check"]].include?(ARGV)

root = File.expand_path("..", __dir__)
codes = {}
table = {}
mutants = []
Dir.chdir(root) do
  Dir.glob("lib/ripr/core/**/*.rb").each do |path|
    analysis = Ripr::Core::Analyzer.call(File.binread(path), path)
    rewritten = Ripr::Core::Instrumenter.call(analysis.fetch(:source), path, analysis.fetch(:sites))
    codes[File.expand_path(path)] = rewritten.fetch(:code)
    table.merge!(rewritten.fetch(:site_table))
    mutants.concat(analysis.fetch(:mutants))
    (analysis.fetch(:warnings) + rewritten.fetch(:warnings)).each { |warning| warn warning }
  end
end
abort "No Core mutation sites were instrumented" if table.empty?

check_mutant = mutants.find do |mutant|
  mutant[:operator] == "arithmetic" && mutant[:original] == "node.value + 1" &&
    table.fetch(mutant[:site], []).include?(mutant[:id])
end
abort "Could not locate the Core arithmetic self-check mutation" unless check_mutant

status = nil
Dir.mktmpdir("ripr-self-mutate") do |directory|
  data = File.join(directory, "instrumented.json")
  bootstrap = File.join(directory, "bootstrap.rb")
  File.write(data, JSON.generate("codes" => codes, "table" => table))
  File.write(bootstrap, <<~RUBY)
    require "json"
    require #{File.join(root, 'lib/ripr/runtime').dump}
    require #{File.join(root, 'lib/ripr/loader').dump}
    payload = JSON.parse(File.read(#{data.dump}))
    Ripr::R.configure(payload.fetch("table"), samples: false)
    loader = Ripr::Loader.new(payload.fetch("codes")).install
    at_exit { loader.uninstall }
  RUBY
  rubyopt = [ENV.fetch("RUBYOPT", nil), "-r#{Shellwords.escape(bootstrap)}"].compact.join(" ")
  environment = { "RUBYOPT" => rubyopt }
  if ARGV == ["--check"]
    check = <<~RUBY
      require "prism"
      require #{File.join(root, 'lib/ripr/core/operators').dump}
      table = JSON.parse(File.read(#{data.dump})).fetch("table")
      node = Prism.parse("2").value.statements.body.first
      Ripr::R.probe = Ripr::Probe.new(table, samples: false)
      Ripr::R.current_test = "self-check"
      original = Ripr::Core::Operators.for(node)
      raise "Core preload was not instrumented" if Ripr::R.probe.snapshot.fetch("reach").empty?
      Ripr::R.probe = nil
      Ripr::R.activate(#{check_mutant.fetch(:site).dump}, #{table.fetch(check_mutant[:site]).index(check_mutant[:id]) + 1})
      mutated = Ripr::Core::Operators.for(node)
      raise "Core activation did not change the result" if original == mutated
      puts JSON.generate("instrumented_files" => #{codes.length}, "sites" => table.length, "activation_verified" => true)
    RUBY
    system(environment, RbConfig.ruby, "-e", check, chdir: root)
  else
    tests = %w[spec/core_analysis_spec.rb spec/call_graph_spec.rb spec/incremental_spec.rb spec/engine_spec.rb
               spec/reporters_spec.rb spec/config_spec.rb]
    arguments = tests.flat_map { |path| ["--tests", path] }
    system(environment, RbConfig.ruby, File.join(root, "exe/ripr"), "--full", "--framework", "rspec",
           "--reporter", "agent", "--report-dir", ".ripr/self-application", "--jobs", "2", "--no-samples",
           *arguments, "lib/ripr/core", chdir: root)
  end
  status = $CHILD_STATUS
end
exit(status.exitstatus || (128 + status.termsig))
