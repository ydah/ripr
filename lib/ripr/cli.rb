# frozen_string_literal: true

require "optparse"
require_relative "../ripr"
require_relative "config"
require_relative "engine/runner"
require_relative "reporters"
require_relative "accept_ledger"
require_relative "snapshot"

module Ripr
  class CLI
    def self.start(arguments = ARGV, stdout: $stdout, stderr: $stderr, retry_full_suite: false, &restart)
      new(arguments.dup, stdout, stderr, retry_full_suite: retry_full_suite, &restart).call
    end

    def initialize(arguments, stdout, stderr, retry_full_suite: false, &restart)
      @arguments = arguments
      @stdout = stdout
      @stderr = stderr
      @overrides = {}
      @restart = restart
      @file_loading = retry_full_suite ? :full : (:prune if restart)
    end

    def call
      command = %w[run list init accept init-skill mcp reach-map].include?(@arguments.first) ? @arguments.shift : "run"
      @list_kind = @arguments.shift if command == "list" && %w[mutants operators].include?(@arguments.first)
      parser.parse!(@arguments)
      return 0 if @help
      return mcp if command == "mcp"

      directory = @arguments.length == 1 && File.directory?(@arguments.first) &&
                  (File.directory?(File.join(@arguments.first, "test")) || File.directory?(File.join(@arguments.first, "spec")))
      if directory
        root = @arguments.shift
        return Dir.chdir(root) { execute(command) }
      end
      execute(command)
    rescue Engine::Runner::RetryFull => e
      raise unless @restart

      @restart.call(e.message)
    rescue OptionParser::ParseError, ArgumentError, Errno::ENOENT => e
      @stderr.puts "ripr: #{e.message}"
      1
    rescue BaselineFailure => e
      @stderr.puts "ripr: #{e.message}"
      4
    rescue StandardError, ScriptError => e
      @stderr.puts "ripr: #{e.class}: #{e.message}"
      @stderr.puts e.backtrace if ENV["RIPR_DEBUG"]
      3
    end

    private

    def parser
      OptionParser.new do |options|
        options.banner = "Usage: ripr [run|list|init|accept|init-skill|mcp|reach-map] [options] [PATHS...]"
        options.on("--since REF") { |v| @overrides[:since] = v }
        options.on("--reach-map FILE", "Select baseline tests for --since using a trusted reach map") { |v| @overrides[:reach_map] = v }
        options.on("--reach-map-files GLOB", "Allow matching independent test files to be skipped (repeatable)") do |pattern|
          (@overrides[:reach_map_files] ||= []) << pattern
        end
        options.on("--scope SCOPE") { |v| @overrides[:scope] = v }
        options.on("--framework FRAMEWORK") { |v| @overrides[:framework] = v }
        options.on("--tests GLOB") { |v| (@overrides[:tests] ||= []) << v }
        options.on("-j", "--jobs N|auto") { |v| @overrides[:jobs] = Integer(v, exception: false) || v }
        options.on("--operators LIST") { |v| @overrides[:operators] = %w[default full].include?(v) ? v : v.split(",") }
        options.on("--reporter NAME") { |v| (@overrides[:reporters] ||= []) << v }
        options.on("--report-dir DIR") { |v| @overrides[:report_dir] = v }
        options.on("--only IDS") { |v| @overrides[:only] = v.split(",") }
        options.on("--threshold N", Float) { |v| @overrides[:thresholds] = { "break" => v } }
        options.on("--timeout-factor F", Float) { |v| (@overrides[:timeout] ||= {})["factor"] = v }
        options.on("--timeout-base MS", Float) { |v| (@overrides[:timeout] ||= {})["base_ms"] = v }
        options.on("--seed N", Integer) { |v| @overrides[:seed] = v }
        options.on("--baseline-runs N", Integer, "Repeat the baseline to detect unstable tests") { |v| @overrides[:baseline_runs] = v }
        options.on("--no-samples") { @overrides[:samples] = false }
        options.on("--boot FILE") { |v| @overrides[:boot] = v }
        options.on("--typecheck CHECKER") { |v| @overrides[:typecheck] = v }
        options.on("--profile", "Write profiling data to profile.json in the report directory") { @overrides[:profile] = true }
        %w[full dry-run fail-on-survived verify-not-infected verify-killed rails include-tests-diff static call-graph-reuse].each do |name|
          options.on("--#{name}") { @overrides[name.tr("-", "_").to_sym] = true }
        end
        options.on("--reason TEXT") { |v| @reason = v }
        options.on("--dir DIR") { |v| @skill_dir = v }
        options.on("--force") { @force = true }
        options.on("--version") do
          @stdout.puts VERSION
          @help = true
        end
        options.on("-h", "--help") do
          @stdout.puts options
          @help = true
        end
      end
    end

    def mcp
      unless @arguments.empty? && @overrides.empty? && !@reason && !@skill_dir && !@force
        raise ArgumentError, "mcp runs from the current project directory without arguments"
      end

      require_relative "mcp_server"
      MCPServer.new(stdin: $stdin, stdout: @stdout, stderr: @stderr).run
    end

    def execute(command)
      config = Config.load(command == "list" ? @overrides.merge(dry_run: true) : @overrides)
      return init if command == "init"
      return init_skill if command == "init-skill"
      return accept(config) if command == "accept"
      return record_reach_map(config) if command == "reach-map"

      if command == "list" && @list_kind == "operators"
        @stdout.puts config[:operators]
        return 0
      end
      raise ArgumentError, "#{command} is not available yet" unless %w[run list].include?(command)

      runner = Engine::Runner.new(config, @arguments, file_loading: @file_loading)
      runner.plan
      results = if command == "list"
                  runner.mutants.map { |mutant| mutant.to_record.merge("status" => "planned") }
                else
                  runner.call do |done, total|
                    @stderr.print "\rripr: mutation workers #{done}/#{total}#{"\n" if done == total}" if @stderr.tty?
                  end
                end
      runner.warnings.each { |message| @stderr.puts "ripr: #{message}" }
      report_started = runner.profile&.now
      summary = Reporters.write(results, runner, config, stdout: @stdout)
      runner.profile&.phase("report", report_started)
      runner.profile&.write(config[:report_dir], results.length, runner.metrics, runner.baseline)
      return 0 if config[:dry_run] || command == "list"
      return 2 if config[:fail_on_survived] && summary.fetch("survived").positive?
      return 2 if config[:thresholds]["break"] && summary.fetch("score") < config[:thresholds].fetch("break")

      0
    end

    def record_reach_map(config)
      path = Engine::Runner.new(config, @arguments).record_reach_map
      @stdout.puts "Wrote #{path}"
      0
    end

    def init
      raise ArgumentError, ".ripr.yml already exists" if File.exist?(".ripr.yml")

      File.write(".ripr.yml", { "include" => ["lib/**/*.rb"], "exclude" => ["lib/**/version.rb"],
                                "framework" => "auto", "scope" => "node", "jobs" => "auto", "operators" => "default",
                                "samples" => true }.to_yaml)
      @stdout.puts "Created .ripr.yml"
      0
    end

    def init_skill
      source = File.expand_path("../../skills/mutation-test-loop/SKILL.md", __dir__)
      target = File.join(@skill_dir || ".claude/skills", "mutation-test-loop", "SKILL.md")
      if File.exist?(target) && !@force && File.read(target) != File.read(source)
        raise ArgumentError, "#{target} has changes; use --force to overwrite"
      end

      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(source, target)
      @stdout.puts "Installed #{target}"
      0
    end

    def accept(config)
      unless @arguments.length == 1 && @reason && !@reason.strip.empty?
        raise ArgumentError,
              "accept requires one mutant ID and --reason TEXT"
      end

      records = Snapshot.new.read.fetch("mutants", {})
      record = records.values.find { |entry| [entry["id"], entry["full_id"]].include?(@arguments.first) }
      raise ArgumentError, "unknown mutant ID; run ripr first" unless record

      runner = Engine::Runner.new(config)
      runner.plan
      mutant = runner.mutants.find { |entry| entry.full_id == record["full_id"] }
      raise ArgumentError, "mutant source changed; rerun ripr before accepting" unless mutant && mutant.method_hash == record["method_hash"]

      AcceptLedger.new.accept(mutant.to_record, reason: @reason)
      @stdout.puts "Accepted #{mutant.id}"
      0
    end
  end
end
