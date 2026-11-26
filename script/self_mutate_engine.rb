# frozen_string_literal: true

require "bundler"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "timeout"
require "tmpdir"
require_relative "../lib/ripr/core/analyzer"
require_relative "../lib/ripr/engine/child"

module SelfMutateEngine
  CACHE_TESTS = %w[spec/cache_cli_spec.rb spec/kill_order_spec.rb].freeze
  CLI_TESTS = ["spec/cli_spec.rb"].freeze
  SUITES = {
    "baseline_cache.rb" => ["spec/baseline_cache_spec.rb", *CACHE_TESTS],
    "child.rb" => %w[spec/engine_spec.rb],
    "method_exits.rb" => %w[spec/method_exits_spec.rb spec/propagation_cli_spec.rb],
    "mutant.rb" => %w[spec/mutation_plan_spec.rb spec/cli_spec.rb],
    "profile.rb" => %w[spec/profile_spec.rb],
    "result_cache.rb" => ["spec/result_cache_spec.rb", *CACHE_TESTS],
    "runner.rb" => %w[spec/mutation_plan_spec.rb spec/cli_spec.rb spec/cache_cli_spec.rb spec/profile_spec.rb],
    "runtime.rb" => %w[spec/runtime_spec.rb spec/instrumenter_spec.rb],
    "scheduler.rb" => %w[spec/kill_order_spec.rb spec/cli_spec.rb spec/propagation_cli_spec.rb],
    "static_run.rb" => CLI_TESTS,
    "type_checker.rb" => %w[spec/type_checker_spec.rb],
    "worker_memory.rb" => %w[spec/worker_memory_spec.rb]
  }.freeze
  PROJECT_FILES = %w[Gemfile Gemfile.lock ripr.gemspec README.md CHANGELOG.md LICENSE.txt
                     {exe,lib,schema,skills,spec,test}/**/*].freeze
  STATUSES = %w[killed not_detected timeout error invalid].freeze

  module_function

  def run(root, jobs:, timeout_seconds:, only:, shard: nil)
    configured_path = Bundler.settings[:path]
    bundle_path = File.expand_path(configured_path, root) if configured_path
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Dir.mktmpdir("ripr-self-mutate") do |workspace|
      project = File.join(workspace, "original")
      FileUtils.mkdir_p(project)
      copy_project(root, project)
      analyses = analyze(project)
      mutants = inventory(analyses, only)
      mutants = shard_mutants(mutants, shard) if shard
      valid, invalid = mutants.partition { |mutant| !mutant[:invalid] }
      raise ArgumentError, "No valid Engine or runtime mutants" if mutants.empty? || (!shard && valid.empty?)

      baselines = run_baselines(project, workspace, valid, jobs, timeout_seconds, bundle_path)
      warn "Engine/runtime original tests passed in #{baselines.size} suites"
      results = run_mutants(project, workspace, valid, analyses, jobs, timeout_seconds, bundle_path)
      results.concat(invalid.map { |mutant| outcome(mutant, "status" => "invalid") })
      report(analyses, baselines, results, seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
    end
  end

  def merge_reports(root, paths, only:)
    analyses = analyze(root)
    expected = inventory(analyses, only).sort_by { |mutant| mutant.fetch(:full_id) }
    reports = paths.map { |path| JSON.parse(File.read(path)) }
    results = reports.flat_map { |shard| shard.fetch("mutants") }.sort_by { |result| result.fetch("full_id") }
    matches = expected.size == results.size && expected.zip(results).all? do |mutant, result|
      fields = outcome(mutant, {})
      fields["location"] = fields.fetch("location").transform_keys(&:to_s)
      status = result.fetch("status")
      fields <= result && STATUSES.include?(status) && (mutant[:invalid] || false) == (status == "invalid")
    end
    raise ArgumentError, "Engine shard reports do not match the mutation inventory" unless matches

    baselines = reports.reduce({}) { |merged, shard| merged.merge(shard.fetch("baselines")) }
    report(analyses, baselines, results, seconds: reports.map { |shard| shard.fetch("seconds") }.max)
  end

  def report(analyses, baselines, results, seconds:)
    counts = STATUSES.to_h { |status| [status, results.count { |result| result.fetch("status") == status }] }
    attempted = results.size - counts.fetch("invalid")
    executed = results.count { |result| result.key?("seconds") }
    score = attempted.zero? ? 0.0 : (100.0 * counts.fetch("killed") / attempted).round(1)
    { "baselines" => baselines, "summary" => counts.merge("attempted" => attempted, "executed" => executed, "score" => score),
      "seconds" => seconds, "warnings" => analyses.values.flat_map { |analysis| analysis.fetch(:warnings) },
      "mutants" => results.sort_by { |result| result.fetch("full_id") } }
  end

  def analyze(project)
    Dir.glob("{lib/ripr/engine/**/*.rb,lib/ripr/runtime.rb}", base: project).to_h do |path|
      source = File.binread(File.join(project, path))
      [path, Ripr::Core::Analyzer.call(source, path, operators: Ripr::Core::Operators::FULL_NAMES, static: true)]
    end
  end

  def inventory(analyses, only)
    mutants = analyses.values.flat_map { |analysis| analysis.fetch(:mutants) }
    return mutants if only.empty?

    missing = only - mutants.flat_map { |mutant| mutant.values_at(:id, :full_id) }
    raise ArgumentError, "Unknown mutant IDs: #{missing.join(', ')}" unless missing.empty?

    mutants.select { |mutant| only.intersect?(mutant.values_at(:id, :full_id)) }
  end

  def shard_mutants(mutants, shard)
    match = %r{\A([1-9]\d*)/([1-9]\d*)\z}.match(shard)
    index, total = match.captures.map(&:to_i) if match
    raise ArgumentError, "--shard must be INDEX/TOTAL with 1 <= INDEX <= TOTAL" unless match && index <= total

    mutants.sort_by { |mutant| mutant.fetch(:full_id) }.each_with_index.filter_map do |mutant, position|
      mutant if position % total == index - 1
    end
  end

  def copy_project(from, to)
    Dir.glob(PROJECT_FILES, base: from).each do |path|
      source = File.join(from, path)
      next unless File.file?(source)

      destination = File.join(to, path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source, destination)
    end
  end

  def suite(path)
    SUITES.fetch(File.basename(path)) { ["spec/engine_spec.rb", *CLI_TESTS] }
  end

  def run_baselines(project, workspace, mutants, jobs, timeout_seconds, bundle_path)
    suites = mutants.map { |mutant| suite(mutant.fetch(:location).fetch(:file)) }.uniq
    results = Ripr::Engine::Child.batch(suites, jobs: jobs, timeout: ->(_) { (timeout_seconds + 10) * 1000 }) do |tests, _|
      Dir.mktmpdir("baseline-", workspace) do |directory|
        copy_project(project, directory)
        run_specs(directory, tests, timeout_seconds: timeout_seconds, bundle_path: bundle_path)
      end
    end
    results.to_h do |tests, result|
      unless result.fetch("status") == "not_detected"
        detail = result.values_at("error", "killed_by", "failure").compact.join("\n")
        raise "Original tests failed for #{tests.join(', ')} (#{result.fetch('status')}): #{detail}"
      end

      [tests.join(" "), result.merge("status" => "passed")]
    end
  end

  def run_mutants(project, workspace, mutants, analyses, jobs, timeout_seconds, bundle_path)
    completed = 0
    progress = lambda do |_, _, _|
      completed += 1
      warn "Engine/runtime mutants: #{completed}/#{mutants.size}" if (completed % 100).zero? || completed == mutants.size
    end
    runs = Ripr::Engine::Child.batch(mutants, jobs: jobs, timeout: ->(_) { (timeout_seconds + 10) * 1000 },
                                              on_result: progress) do |mutant, _|
      path = mutant.fetch(:location).fetch(:file)
      Dir.mktmpdir("#{mutant.fetch(:id)}-", workspace) do |directory|
        copy_project(project, directory)
        source = analyses.fetch(path).fetch(:source)
        File.binwrite(File.join(directory, path), Ripr::Core::Instrumenter.mutate(source, mutant))
        run_specs(directory, suite(path), timeout_seconds: timeout_seconds, bundle_path: bundle_path)
      end
    end
    runs.map { |mutant, result| outcome(mutant, result) }
  end

  def outcome(mutant, result)
    fields = mutant.slice(:id, :full_id, :location, :subject, :operator, :original, :mutated, :static)
    fields.transform_keys(&:to_s).merge(result)
  end

  def run_specs(directory, tests, timeout_seconds:, bundle_path:)
    report = File.join(directory, "rspec-report.json")
    log = File.join(directory, "rspec-output.log")
    tmp = File.join(directory, "tmp")
    FileUtils.mkdir_p(tmp)
    FileUtils.rm_f(report)
    environment = { "BUNDLE_GEMFILE" => File.join(directory, "Gemfile"), "BUNDLE_PATH" => bundle_path,
                    "RUBYLIB" => nil, "RUBYOPT" => "-rbundler/setup", "SPEC_OPTS" => nil, "TMPDIR" => tmp }
    command = [RbConfig.ruby, "-S", "rspec", "--options", File::NULL, "--require", "./spec/spec_helper",
               "--format", "json", "--out", report, "--failure-exit-code", "1", "--error-exit-code", "2", "--fail-fast", *tests]
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pid = Process.spawn(environment, *command, chdir: directory, pgroup: true, out: log, err: %i[child out])
    result = begin
      _, status = Timeout.timeout(timeout_seconds) { Process.wait2(pid) }
      classify(status, report, log)
    rescue Timeout::Error
      cleanup_error = stop_processes(pid)
      Process.wait(pid)
      { "status" => "timeout", "cleanup_error" => cleanup_error }.compact
    end
    result.merge("seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
  end

  def classify(status, report, log)
    return { "status" => "error", "error" => "RSpec terminated by signal #{status.termsig}" } if status.signaled?

    data = JSON.parse(File.read(report))
    summary = data.fetch("summary")
    fields = { "examples" => summary.fetch("example_count"), "failures" => summary.fetch("failure_count") }
    if summary.fetch("errors_outside_of_examples_count").zero? && fields.fetch("examples").positive?
      return fields.merge("status" => "not_detected") if status.success? && fields.fetch("failures").zero?

      if status.exitstatus == 1 && fields.fetch("failures").positive?
        failure = data.fetch("examples").find { |example| example.fetch("status") == "failed" }
        return fields.merge("status" => "killed", "killed_by" => failure.fetch("full_description"),
                            "failure" => failure.fetch("exception").fetch("message"))
      end
    end
    messages = data.fetch("messages", [])
    detail = messages.empty? ? log_tail(log) : messages.join("\n")
    { "status" => "error", "error" => "RSpec exited #{status.exitstatus}: #{detail}" }
  rescue Errno::ENOENT, JSON::ParserError, KeyError => e
    { "status" => "error", "error" => "Incomplete RSpec report (#{e.class}): #{log_tail(log)}" }
  end

  def log_tail(log)
    text = File.binread(log)
    text.byteslice([text.bytesize - 4096, 0].max..).force_encoding(Encoding::UTF_8).scrub
  end

  def stop_processes(pid)
    descendants = [pid]
    send_signal("STOP", -pid)
    2.times do
      output, status = Open3.capture2("ps", "-eo", "pid=,ppid=")
      raise "Cannot inspect Engine/runtime test process tree" unless status.success?

      rows = output.lines.map { |line| line.split.map(&:to_i) }
      loop do
        children = rows.filter_map { |child, parent| child if descendants.include?(parent) && !descendants.include?(child) }
        break if children.empty?

        descendants.concat(children)
      end
      descendants.each { |child| send_signal("STOP", child) }
    end
    nil
  rescue Errno::EACCES, Errno::EPERM => e
    e.message
  ensure
    send_signal("KILL", -pid)
    descendants.reverse_each { |child| send_signal("KILL", child) }
  end

  def send_signal(signal, target)
    Process.kill(signal, target)
  rescue Errno::ESRCH
    nil
  end

  def main(arguments)
    options = { jobs: 4, timeout_seconds: 45, only: [] }
    merge = false
    parser = OptionParser.new do |cli|
      cli.banner = <<~USAGE.chomp
        Usage: ruby script/self_mutate_engine.rb [--jobs N] [--timeout-seconds N] [--only ID] [--shard INDEX/TOTAL]
               ruby script/self_mutate_engine.rb [--only ID] --merge REPORT...
      USAGE
      cli.on("--jobs N", Integer) { |number| options[:jobs] = number }
      cli.on("--timeout-seconds N", Integer) { |seconds| options[:timeout_seconds] = seconds }
      cli.on("--only ID") { |id| options[:only] << id }
      cli.on("--shard INDEX/TOTAL") { |shard| options[:shard] = shard }
      cli.on("--merge") { merge = true }
    end
    parser.parse!(arguments)
    root = File.expand_path("..", __dir__)

    if merge
      abort parser.to_s if arguments.empty? || options[:shard]

      puts JSON.pretty_generate(merge_reports(root, arguments, only: options.fetch(:only)))
    else
      abort parser.to_s unless arguments.empty? && options.values_at(:jobs, :timeout_seconds).all?(&:positive?)

      puts JSON.pretty_generate(run(root, **options))
    end
  rescue ArgumentError, RuntimeError => e
    abort e.message
  end
end

SelfMutateEngine.main(ARGV) if $PROGRAM_NAME == __FILE__
