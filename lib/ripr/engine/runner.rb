# frozen_string_literal: true

require_relative "../core/analyzer"
require_relative "../core/instrumenter"
require_relative "../core/classifier"
require_relative "../runtime"
require_relative "../loader"
require_relative "../git"
require_relative "../accept_ledger"
require_relative "child"
require_relative "baseline_cache"
require_relative "result_cache"
require_relative "scheduler"
require "pathname"
require "tempfile"

module Ripr
  module Engine
    class Runner
      attr_reader :mutants, :warnings, :baseline, :framework, :sources, :static, :metrics

      def initialize(config, paths = [])
        @config = config
        @paths = paths
        @warnings = []
        @mutants = []
        @sources = {}
        @table = {}
        @codes = {}
        @static = 0
        @metrics = { "baseline_reused" => false, "baseline_tests_run" => 0, "reused" => 0 }
      end

      def plan
        return @mutants if @planned

        patterns = if @paths.empty?
                     @config[:include]
                   else
                     @paths.map { |p| File.directory?(p) ? "#{p}/**/*.rb" : p }
                   end
        files = patterns.flat_map { |pattern| Dir.glob(pattern) }.uniq.sort.select { |p| File.file?(p) && p.end_with?(".rb") }
        files.map! { |path| relative(path) }
        files.uniq!
        files.reject! { |path| @config[:exclude].any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME) } }
        files.each do |path|
          source = File.read(path)
          @sources[path] = source
          analysis = Core::Analyzer.call(source, path, operators: @config[:operators], arid_callees: @config[:arid_callees])
          instrumented = Core::Instrumenter.call(source, path, analysis.fetch(:sites))
          @codes[File.expand_path(path)] = instrumented.fetch(:code)
          @table.merge!(instrumented.fetch(:site_table))
          analysis.fetch(:mutants).each do |mutant|
            mutant[:invalid] = true if instrumented.fetch(:invalid).include?(mutant[:id])
          end
          @mutants.concat(analysis.fetch(:mutants).map { |mutant| stringify(mutant) })
          @warnings.concat(analysis.fetch(:warnings) + instrumented.fetch(:warnings))
          @static += analysis.fetch(:static)
        end
        acceptances = AcceptLedger.new.read.to_h { |entry| [entry.fetch("full_id"), entry] }
        @mutants.each do |mutant|
          entry = acceptances[mutant.fetch("full_id")]
          next unless entry

          if entry["method_hash"] == mutant["method_hash"]
            mutant["accepted"] ||= entry.fetch("reason")
          else
            @warnings << "stale acceptance #{mutant.fetch('id')}: method changed; review the reason again"
          end
        end
        @planned = true
        @mutants
      end

      def call
        previous_ripr = ENV.fetch("RIPR", nil)
        plan unless @planned
        selected = select_mutants(@mutants)
        return selected.map { |m| m.merge("status" => "planned") } if @config[:dry_run]
        return [] if selected.empty?

        ENV["RIPR"] = "1"
        @loader = Loader.new(@codes).install
        R.configure(@table, samples: @config[:samples])
        R.probe = Probe.new(@table, samples: @config[:samples])
        adapter = load_tests
        load_reached = R.probe.snapshot.fetch("load_reached")
        R.probe = nil
        @cache = ResultCache.new(@config, sources: @sources, test_files: @test_files, framework: @framework, mutants: @mutants)
        prepare_baseline(adapter, load_reached)
        results = Scheduler.new(@config, @baseline, @table, @cache, warnings: @warnings, metrics: @metrics).call(selected, adapter)
        @cache.write(results, @baseline, @metrics)
        results
      ensure
        @loader&.uninstall
        R.reset
        previous_ripr.nil? ? ENV.delete("RIPR") : ENV["RIPR"] = previous_ripr
      end

      private

      def select_mutants(mutants)
        result = mutants
        if @config[:since] && !@config[:full]
          changed = begin
            Git.new.changed_lines(@config[:since])
          rescue Error => e
            raise ArgumentError, e.message
          end
          result = result.select do |mutant|
            location = mutant.fetch("location")
            range = if @config[:scope] == "method"
                      mutant.fetch("method_start")..mutant.fetch("method_end")
                    else
                      location.fetch("line")..location.fetch("end_line")
                    end
            changed.fetch(location.fetch("file"), []).any? { |line| range.cover?(line) }
          end
        end
        unless @config[:only].empty?
          missing = @config[:only] - mutants.flat_map { |m| [m["id"], m["full_id"]] }
          raise ArgumentError, "unknown mutant ids: #{missing.join(', ')}" unless missing.empty?

          result = result.select { |m| @config[:only].include?(m["id"]) || @config[:only].include?(m["full_id"]) }
        end
        result
      end

      def load_tests
        %w[lib test spec].reverse_each { |directory| $LOAD_PATH.unshift(File.expand_path(directory)) }
        @framework = @config[:framework]
        @framework = Dir.glob("spec/**/*_spec.rb").empty? ? "minitest" : "rspec" if @framework == "auto"
        patterns = @config[:tests] || (@framework == "rspec" ? "spec/**/*_spec.rb" : "test/**/*_test.rb")
        files = Array(patterns).flat_map { |pattern| Dir.glob(pattern) }.map { |file| relative(file) }.uniq.sort
        @test_files = files
        raise ArgumentError, "no test files found" if files.empty?

        require_relative "../integration/#{@framework}"
        klass = @framework == "rspec" ? Integration::RSpec : Integration::Minitest
        adapter = klass.new(files, seed: @config[:seed])
        capture_load_output { adapter.load }
        raise BaselineFailure, "no tests were discovered" if adapter.tests.empty?

        adapter
      end

      # rubocop:disable-next Style/GlobalStdStream -- Capture descriptor 1, including direct STDOUT writes.
      def capture_load_output
        Tempfile.create("ripr-load") do |output|
          STDOUT.flush
          descriptor = STDOUT.dup
          stream = $stdout
          begin
            STDOUT.reopen(output)
            $stdout = STDOUT
            yield
          ensure
            STDOUT.flush
            STDOUT.reopen(descriptor)
            $stdout = stream
            descriptor.close
            output.rewind
            IO.copy_stream(output, STDERR)
          end
        end
      end

      def prepare_baseline(adapter, load_reached)
        tests = adapter.tests.map { |test| test.merge("file" => relative(test.fetch("file"))) }
        cache = BaselineCache.new(@cache.previous["baseline"], env_hash: @cache.baseline_env_hash,
                                                               source_hash: @cache.source_hash, test_hashes: @cache.test_hashes,
                                                               tests: tests, full: @config[:full])
        fresh = unless cache.test_ids == []
                  Child.call(timeout_ms: 60_000) do
                    probe = Probe.new(@table, samples: @config[:samples])
                    R.probe = probe
                    adapter.run(cache.test_ids).merge("probe" => probe.snapshot)
                  end
                end
        if fresh && !fresh["success"]
          failures = fresh["failures"] || [fresh["error"] || fresh["status"]]
          messages = failures.map { |failure| failure.is_a?(Hash) ? failure["message"] : failure }
          raise BaselineFailure, "baseline failed: #{messages.join('; ')}"
        end
        fresh&.fetch("tests")&.each_value { |test| test["file"] = relative(test.fetch("file")) }
        @baseline = cache.combine(fresh, load_reached: load_reached)
        @metrics["baseline_reused"] = cache.reused_count.positive?
        @metrics["baseline_tests_run"] = fresh ? fresh.fetch("tests").length : 0
      end

      def relative(path)
        Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(Dir.pwd)).to_s
      end

      def stringify(value)
        case value
        when Hash then value.to_h { |key, child| [key.to_s, stringify(child)] }
        when Array then value.map { |child| stringify(child) }
        else value
        end
      end
    end
  end
end
