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
require_relative "static_run"
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
          analysis = Core::Analyzer.call(
            File.binread(path), path, operators: @config[:operators], arid_callees: @config[:arid_callees], static: @config[:static]
          )
          source = @sources[path] = analysis.fetch(:source)
          instrumented = Core::Instrumenter.call(source, path, analysis.fetch(:sites))
          @codes[File.expand_path(path)] = instrumented.fetch(:code) unless instrumented.fetch(:site_table).empty?
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

      def call(&)
        plan unless @planned
        candidates = select_ids(@mutants)
        changes = changed_lines
        selected = changes ? select_source_mutants(candidates, changes) : candidates
        test_changes = changed_test_files(changes)
        observed = test_changes.empty? ? selected : candidates
        return selected.map { |m| m.merge("status" => "planned") } if @config[:dry_run]
        return [] if observed.empty?

        if @config[:call_graph_reuse] && !(@config[:boot] || @config[:rails] || @config[:static] || @config[:verify_killed])
          require_relative "../core/call_graph"
          @call_graph = Core::CallGraph.new(@sources)
        end
        probe_table = @table.slice(*observed.map { |mutant| mutant.fetch("site") }.uniq)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        with_project(probe: Probe.new(probe_table, samples: @config[:samples])) do |adapter|
          boot_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
          load_reached = R.probe.snapshot.fetch("load_reached")
          R.probe = nil
          @rails&.prepare_workers([@config[:jobs], observed.length].min)
          @cache = ResultCache.new(@config, sources: @sources, test_files: @test_files, framework: @framework, mutants: @mutants,
                                            test_ids: adapter.tests.map { |test| test.fetch("id") }, probe_sites: probe_table.keys,
                                            graph: @call_graph, load_dependencies: @load_dependencies)
          prepare_baseline(adapter, probe_table, load_reached)
          selected |= select_test_mutants(candidates, test_changes) unless test_changes.empty?
          selected = check_types(selected) if @config[:typecheck]
          static_run = StaticRun.new(@config, @paths, boot_ms: boot_ms)
          scheduler = Scheduler.new(@config, @baseline, @table, @cache, warnings: @warnings, metrics: @metrics,
                                                                        rails: @rails, static_run: static_run)
          results = scheduler.call(selected, adapter, &)
          @cache.write(results, @baseline, @metrics)
          results
        end
      end

      def run_static(full_id, test_ids)
        plan
        mutant = @mutants.find { |entry| entry["full_id"] == full_id && entry["static"] } if full_id
        raise ArgumentError, "static mutation changed before execution: #{full_id}" if full_id && !mutant

        with_project(active: mutant) { |adapter| capture_load_output { adapter.run(test_ids, fail_fast: true) } }
      end

      private

      def with_project(probe: nil, active: nil)
        previous_ripr = ENV.fetch("RIPR", nil)
        ENV["RIPR"] = "1"
        if @config[:rails]
          require_relative "../integration/rails"
          @rails = Integration::Rails.new(boot: @config[:boot])
          capture_load_output { @rails.prepare }
        end
        reject_preloaded_sources
        @loader = Loader.new(@codes).install
        R.configure(@table, samples: @config[:samples])
        R.probe = probe
        if active
          site = active.fetch("site")
          R.activate(site, @table.fetch(site).index(active.fetch("id")) + 1)
        end
        if @rails
          capture_load_output { @rails.boot }
        elsif (boot = @config[:boot])
          raise ArgumentError, "boot file does not exist: #{boot}" unless File.file?(boot)

          capture_load_output { require File.expand_path(boot) }
        end
        yield load_tests
      ensure
        @loader&.uninstall
        @rails&.close
        R.reset
        previous_ripr.nil? ? ENV.delete("RIPR") : ENV["RIPR"] = previous_ripr
      end

      def reject_preloaded_sources
        loaded = $LOADED_FEATURES.filter_map do |feature|
          File.realpath(feature)
        rescue Errno::ENOENT, Errno::ENOTDIR
          nil
        end
        @codes.each do |path, code|
          next unless loaded.include?(File.realpath(path))
          next if Loader.instrumented?(path, code)

          raise ArgumentError,
                "target #{relative(path)} was loaded before ripr; start ripr without pre-requiring target source"
        end
      end

      def changed_lines
        return unless @config[:since] && !@config[:full]

        Git.new.changed_lines(@config[:since], include_all_paths: @config[:include_tests_diff])
      rescue Error => e
        raise ArgumentError, e.message
      end

      def select_ids(mutants)
        return mutants if @config[:only].empty?

        missing = @config[:only] - mutants.flat_map { |m| [m["id"], m["full_id"]] }
        raise ArgumentError, "unknown mutant ids: #{missing.join(', ')}" unless missing.empty?

        mutants.select { |m| @config[:only].include?(m["id"]) || @config[:only].include?(m["full_id"]) }
      end

      def select_source_mutants(mutants, changed)
        mutants.select do |mutant|
          location = mutant.fetch("location")
          range = if @config[:scope] == "method"
                    mutant.fetch("method_start")..mutant.fetch("method_end")
                  else
                    location.fetch("line")..location.fetch("end_line")
                  end
          changed.fetch(location.fetch("file"), []).any? { |line| range.cover?(line) }
        end
      end

      def changed_test_files(changes)
        return [] unless changes && @config[:include_tests_diff]

        patterns = Array(@config[:tests]).map { |pattern| relative(pattern) }
        changes.keys.select do |file|
          %w[.rspec .rspec-local].include?(file) || file.start_with?("test/", "spec/") ||
            patterns.any? { |pattern| File.fnmatch?(pattern, file, File::FNM_PATHNAME) }
        end
      end

      def select_test_mutants(mutants, changed_files)
        definitions = @baseline.fetch("tests")
        files = definitions.values.map { |test| test.fetch("file") }
        return mutants unless (changed_files - files).empty?

        tests = tests_defined_in(definitions, changed_files)
        probe = @baseline.fetch("probe")
        previous = @cache.previous["baseline"]
        previous_tests = tests_defined_in(previous["tests"], changed_files) if previous.is_a?(Hash) && previous["tests"].is_a?(Hash)
        previous_probe = previous["probe"] if previous.is_a?(Hash)
        previous_reach = previous_probe["reach"] if previous_probe.is_a?(Hash)
        mutants.select do |mutant|
          site = mutant.fetch("site")
          old_ids = previous_reach[site] if previous_reach.is_a?(Hash)
          probe.fetch("load_reached").include?(site) || probe.fetch("reach").fetch(site, []).intersect?(tests) ||
            (previous_tests && old_ids.is_a?(Array) && old_ids.intersect?(previous_tests))
        end
      end

      def tests_defined_in(definitions, files)
        definitions.filter_map { |id, test| id if test.is_a?(Hash) && files.include?(test["file"]) }
      end

      def check_types(mutants)
        return mutants if mutants.all? { |mutant| mutant["accepted"] || mutant["invalid"] }

        require_relative "type_checker"
        TypeChecker.open(@config[:typecheck]) do |checker|
          mutants.map do |mutant|
            next mutant if mutant["accepted"] || mutant["invalid"]

            path = mutant.fetch("location").fetch("file")
            code = Core::Instrumenter.mutate(@sources.fetch(path), mutant.transform_keys(&:to_sym))
            diagnostic = checker.check(path, code)
            next mutant unless diagnostic

            @warnings << "typecheck excluded #{mutant.fetch('id')}: #{diagnostic}"
            mutant.merge("invalid" => true, "invalid_reason" => diagnostic)
          end
        end
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
        capture_load_output do
          if @call_graph
            _, @load_dependencies = @call_graph.trace { adapter.load }
          else
            adapter.load
          end
        end
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

      def prepare_baseline(adapter, probe_table, load_reached)
        tests = adapter.tests.map { |test| test.merge("file" => relative(test.fetch("file"))) }
        cache = BaselineCache.new(@cache.previous["baseline"], env_hash: @cache.baseline_env_hash,
                                                               source_hash: @cache.source_hash, test_hashes: @cache.test_hashes,
                                                               tests: tests, full: @config[:full])
        fresh = unless cache.test_ids == []
                  Child.call(timeout_ms: 60_000 + (@rails&.worker_timeout_ms || 0)) do
                    probe = Probe.new(probe_table, samples: @config[:samples])
                    R.probe = probe
                    result = if @rails
                               @rails.with_worker(0) { adapter.run(cache.test_ids) }
                             else
                               adapter.run(cache.test_ids)
                             end
                    result.merge("probe" => probe.snapshot)
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
