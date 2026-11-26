# frozen_string_literal: true

require_relative "../core/analyzer"
require_relative "../core/instrumenter"
require_relative "../core/classifier"
require_relative "../runtime"
require_relative "../loader"
require_relative "../git"
require_relative "../accept_ledger"
require_relative "child"
require_relative "mutant"
require_relative "baseline_cache"
require_relative "result_cache"
require_relative "scheduler"
require_relative "static_run"
require_relative "worker_memory"
require "pathname"
require "tempfile"

module Ripr
  module Engine
    class Runner
      attr_reader :mutants, :warnings, :baseline, :framework, :sources, :static, :metrics, :profile, :changed_source_lines

      class RetryFull < Ripr::Error; end

      Selection = Data.define(:candidates, :selected, :changed_tests) do
        def observed
          changed_tests.empty? ? selected : candidates
        end
      end
      private_constant :Selection

      def initialize(config, paths = [], file_loading: nil)
        @config = config
        @paths = paths
        @file_loading = file_loading
        @warnings = []
        @mutants = []
        @sources = {}
        @table = {}
        @codes = {}
        @static = 0
        @changed_source_lines = {}
        @metrics = { "baseline_reused" => false, "baseline_tests_run" => 0, "reused" => 0 }
        return unless @config[:profile]

        require_relative "profile"
        @profile = Profile.new
      end

      def plan(skipped: nil)
        return @mutants if @planned

        started = @profile&.now
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
            File.binread(path), path,
            operators: @config[:operators], arid_callees: @config[:arid_callees], static: @config[:static], skipped: skipped
          )
          source = @sources[path] = analysis.fetch(:source)
          instrument_started = @profile&.now
          instrumented = Core::Instrumenter.call(source, path, analysis.fetch(:sites))
          @profile&.phase("instrument", instrument_started)
          @codes[File.expand_path(path)] = instrumented.fetch(:code) unless instrumented.fetch(:site_table).empty?
          @table.merge!(instrumented.fetch(:site_table))
          unsupported = instrumented.fetch(:invalid)
          planned = analysis.fetch(:mutants).map do |mutant|
            reason = if mutant[:invalid] then "replacement is invalid Ruby"
                     elsif unsupported.include?(mutant.fetch(:id)) then "unsupported instrumentation"
                     end
            mutant = mutant.merge(invalid_reason: reason) if reason
            Mutant.from_analysis(mutant, invalid: reason ? true : nil)
          end
          @mutants.concat(planned)
          @warnings.concat(analysis.fetch(:warnings) + instrumented.fetch(:warnings))
          @static += analysis.fetch(:static)
        end
        acceptances = AcceptLedger.new.read.to_h { |entry| [entry.fetch("full_id"), entry] }
        @mutants.map! do |mutant|
          entry = acceptances[mutant.full_id]
          next mutant unless entry

          if entry["method_hash"] == mutant.method_hash
            mutant.accepted ? mutant : mutant.with(accepted: entry.fetch("reason").freeze)
          else
            @warnings << "stale acceptance #{mutant.id}: method changed; review the reason again"
            mutant
          end
        end
        @mutants.freeze
        collect_skipped_mutants(skipped) if skipped
        @planned = true
        @profile&.phase("plan", started)
        @mutants
      end

      def call(&)
        plan unless @planned
        selection = select_mutants
        return selection.selected.map { |mutant| mutant.to_record.merge("status" => "planned") } if @config[:dry_run]
        return [] if selection.observed.empty?

        prepare_reach_selection(selection)
        prepare_call_graph
        prepare_test_file_loading
        run_project(selection, &)
      end

      def run_static(full_id, test_ids)
        plan
        mutant = @mutants.find { |entry| entry.full_id == full_id && entry.static } if full_id
        raise ArgumentError, "static mutation changed before execution: #{full_id}" if full_id && !mutant

        with_project(active: mutant) { |adapter| capture_load_output { adapter.run(test_ids, fail_fast: true) } }
      end

      def record_reach_map
        raise ArgumentError, "--baseline-runs greater than one requires run" if @config[:baseline_runs] > 1

        if @config[:since] || @config[:dry_run] || !@config[:only].empty?
          raise ArgumentError, "reach-map requires a complete baseline without --since, --only, or --dry-run"
        end

        require_relative "reach_map"
        git = Git.new
        base = git.clean_head
        plan
        reach_map = ReachMap.new(@sources, @config)
        result, tests, database_inputs = with_project(observer: reach_map) do |adapter|
          prepare_rails_workers(1, observer: reach_map)
          database_inputs = reach_map.database_inputs(@rails)
          tests = adapter.tests
          result = run_baseline do
            baseline = reach_map.capture(loading: false) { run_baseline_tests(adapter, nil) }
            baseline.merge("observations" => reach_map.observations)
          end
          [result, tests, database_inputs]
        end
        reach_map.write(result, tests, @test_files, @framework, base, git, database_inputs: database_inputs)
      end

      def public_subjects
        MethodExits.public_subjects(method_targets)
      end

      private

      def collect_skipped_mutants(skipped)
        @mutants.each do |mutant|
          reason = mutant.accepted ? "accepted: #{mutant.accepted}" : mutant.invalid_reason
          next unless reason

          location = mutant.location
          skipped << [location.file, location.line, location.column, reason]
        end
      end

      def select_mutants
        started = @profile&.now
        candidates = select_ids(@mutants)
        changes = changed_lines
        @changed_source_lines = changes || {}
        selected = changes ? select_source_mutants(candidates, changes) : candidates
        selection = Selection.new(candidates, selected, changed_test_files(changes))
        @profile&.phase("plan", started)
        selection
      end

      def prepare_call_graph
        return unless @config[:call_graph_reuse] && !(@config[:boot] || @config[:rails] || @config[:static] || @config[:verify_killed])
        return if @config[:baseline_runs] > 1

        require_relative "../core/call_graph"
        @call_graph = Core::CallGraph.new(@sources, rails: @config[:rails])
      end

      def prepare_reach_selection(selection)
        return unless @config[:reach_map] && @file_loading != :full

        if @config[:baseline_runs] > 1
          @warnings << "reach-map fallback: repeated baselines require all test files"
          return
        end

        require_relative "reach_selection"
        @reach_selection = ReachSelection.new(@config, @sources, selection.observed)
      rescue ReachSelection::Unusable => e
        @warnings << "reach-map fallback: #{e.message}"
      end

      def prepare_test_file_loading
        return unless @file_loading == :prune && @reach_selection && !@config[:reach_map_files].empty?

        framework = test_framework
        files = test_file_paths(framework)
        allowed = Dir.glob(@config[:reach_map_files]).map { |path| relative(path) }
        return unless files.intersect?(allowed)

        retained = @reach_selection.load_files(files, framework, allowed:)
        return if retained == files

        @planned_test_discovery = [framework, files]
        @retained_test_files = retained
      end

      def run_project(selection, &)
        probe_table = @table.slice(*selection.observed.map(&:site).uniq)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @config[:boot] || @config[:rails]
          require_relative "boot_context"
          @boot_context = BootContext.new(boot: @config[:boot], rails: @config[:rails], source_paths: @sources.keys)
        end
        with_project(probe: Probe.new(probe_table, samples: @config[:samples]), observer: @reach_selection) do |adapter|
          boot_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
          load_reached = R.probe.snapshot.fetch("load_reached")
          R.probe = nil
          worker_config = if @rails && @config[:baseline_runs] > 1
                            Config.new(@config.to_h.merge(jobs: 1))
                          else
                            @config.with_worker_limit { WorkerMemory.limit }
                          end
          prepare_rails_workers([worker_config[:jobs], selection.observed.length].min, observer: @reach_selection)
          boot_digest = @boot_context&.fingerprint(sqlite_snapshots: @rails&.cache_snapshot_paths)
          @profile&.phase("boot", started)
          baseline_started = @profile&.now
          method_hashes = @mutants.to_h { |mutant| [mutant.full_id, mutant.method_hash] }
          @cache = ResultCache.new(@config, sources: @sources, test_files: @test_files, framework: @framework, method_hashes:,
                                            test_ids: adapter.tests.map { |test| test.fetch("id") }, probe_sites: probe_table.keys,
                                            graph: @call_graph, load_dependencies: @load_dependencies, boot_digest: boot_digest)
          Process.warmup
          prepare_baseline(adapter, probe_table, load_reached)
          @profile&.phase("baseline", baseline_started)
          execute_selection(selection, adapter, worker_config, boot_ms, &)
        end
      rescue StandardError, ScriptError => e
        raise unless @narrowed_test_files && !@metrics["baseline_reach_map"]

        raise RetryFull, e.message
      end

      def execute_selection(selection, adapter, worker_config, boot_ms, &)
        started = @profile&.now
        selected = selection.selected
        selected |= select_test_mutants(selection.candidates, selection.changed_tests) unless selection.changed_tests.empty?
        selected = check_types(selected) if @config[:typecheck]
        static_run = StaticRun.new(worker_config, @paths, boot_ms: boot_ms)
        scheduler = Scheduler.new(worker_config, @baseline, @table, @cache, targets: method(:method_targets), warnings: @warnings,
                                                                            metrics: @metrics, rails: @rails,
                                                                            static_run: static_run, profile: @profile)
        results = scheduler.call(selected, adapter, &)
        @profile&.phase("mutation", started)
        @cache.write(results, @baseline, @metrics) unless @metrics["baseline_reach_map"]
        results
      end

      def method_targets
        @method_targets ||= MethodExits.targets(@mutants)
      end

      def with_project(probe: nil, active: nil, observer: nil)
        previous_ripr = ENV.fetch("RIPR", nil)
        ENV["RIPR"] = "1"
        adapter = observer ? observer.capture { load_project(probe, active) } : load_project(probe, active)
        yield adapter
      ensure
        @loader&.uninstall
        @rails&.close
        R.reset
        previous_ripr.nil? ? ENV.delete("RIPR") : ENV["RIPR"] = previous_ripr
      end

      def load_project(probe, active)
        if @config[:rails]
          require_relative "../integration/rails"
          @rails = Integration::Rails.new(boot: @config[:boot])
          capture_load_output { observe_boot { @rails.prepare } }
        end
        reject_preloaded_sources
        @loader = Loader.new(@codes).install
        R.configure(@table, samples: @config[:samples])
        R.probe = probe
        if active
          site = active.site
          R.activate(site, @table.fetch(site).index(active.id) + 1)
        end
        if @rails
          capture_load_output { observe_boot { @rails.boot } }
        elsif (boot = @config[:boot])
          raise ArgumentError, "boot file does not exist: #{boot}" unless File.file?(boot)

          capture_load_output { observe_boot { require File.expand_path(boot) } }
        end
        observe_boot { load_tests }
      end

      def observe_boot(&)
        @boot_context ? @boot_context.observe(&) : yield
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

        missing = @config[:only] - mutants.flat_map { |mutant| [mutant.id, mutant.full_id] }
        raise ArgumentError, "unknown mutant ids: #{missing.join(', ')}" unless missing.empty?

        mutants.select { |mutant| @config[:only].include?(mutant.id) || @config[:only].include?(mutant.full_id) }
      end

      def select_source_mutants(mutants, changed)
        mutants.select do |mutant|
          location = mutant.location
          range = if @config[:scope] == "method"
                    mutant.method_start..mutant.method_end
                  else
                    location.line..location.end_line
                  end
          changed.fetch(location.file, []).any? { |line| range.cover?(line) }
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
          site = mutant.site
          old_ids = previous_reach[site] if previous_reach.is_a?(Hash)
          probe.fetch("load_reached").include?(site) || probe.fetch("reach").fetch(site, []).intersect?(tests) ||
            (previous_tests && old_ids.is_a?(Array) && old_ids.intersect?(previous_tests))
        end
      end

      def tests_defined_in(definitions, files)
        definitions.filter_map { |id, test| id if test.is_a?(Hash) && files.include?(test["file"]) }
      end

      def check_types(mutants)
        return mutants if mutants.all? { |mutant| mutant.accepted || mutant.invalid }

        require_relative "type_checker"
        TypeChecker.open(@config[:typecheck]) do |checker|
          mutants.map do |mutant|
            next mutant if mutant.accepted || mutant.invalid

            path = mutant.location.file
            code = Core::Instrumenter.mutate(@sources.fetch(path), mutant.to_h)
            diagnostic = checker.check(path, code)
            next mutant unless diagnostic

            @warnings << "typecheck excluded #{mutant.id}: #{diagnostic}"
            mutant.with(invalid: true, invalid_reason: diagnostic.freeze)
          end
        end
      end

      def load_tests
        %w[lib test spec].reverse_each { |directory| $LOAD_PATH.unshift(File.expand_path(directory)) }
        @framework = test_framework
        @test_files = test_file_paths(@framework)
        if @planned_test_discovery && @planned_test_discovery != [@framework, @test_files]
          raise RetryFull, "test file discovery changed during boot"
        end
        raise ArgumentError, "no test files found" if @test_files.empty?

        require_relative "../integration/#{@framework}"
        @narrowed_test_files = !@retained_test_files.nil?
        files = @retained_test_files || @test_files
        adapter = if @framework == "rspec"
                    Integration::RSpec.new(files, seed: @config[:seed], seed_random: @config[:baseline_runs] > 1)
                  else
                    Integration::Minitest.new(files, seed: @config[:seed])
                  end
        capture_load_output do
          if @call_graph && !@boot_context
            _, @load_dependencies = @call_graph.trace { adapter.load }
          else
            adapter.load
            @load_dependencies = [] if @boot_context
          end
        end
        raise BaselineFailure, "no tests were discovered" if adapter.tests.empty?

        adapter
      end

      def test_framework
        framework = @config[:framework]
        return framework unless framework == "auto"

        Dir.glob("spec/**/*_spec.rb").empty? ? "minitest" : "rspec"
      end

      def test_file_paths(framework)
        patterns = @config[:tests] || (framework == "rspec" ? "spec/**/*_spec.rb" : "test/**/*_test.rb")
        Array(patterns).flat_map { |pattern| Dir.glob(pattern) }.map { |file| relative(file) }.uniq.sort
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
                                                               tests: tests, full: @config[:full] || @config[:reach_map])
        if @config[:baseline_runs] > 1
          require_relative "baseline_stability"
          stability = BaselineStability.new(@config[:baseline_runs], @warnings)
          fresh = stability.call { |ids| probe_baseline(adapter, probe_table, ids, allow_failure: true, record_outcomes: true) }
          @metrics["baseline_tests_run"] = stability.attempted_tests
        else
          fresh = reach_baseline(adapter, probe_table, load_reached)
          fresh ||= probe_baseline(adapter, probe_table, cache.test_ids) unless cache.test_ids == []
          @metrics["baseline_tests_run"] = fresh ? fresh.fetch("tests").length : 0
        end
        fresh&.fetch("tests")&.each_value { |test| test["file"] = relative(test.fetch("file")) }
        @baseline = cache.combine(fresh, load_reached: load_reached)
        @metrics["baseline_reused"] = cache.reused_count.positive?
      end

      def reach_baseline(adapter, probe_table, load_reached)
        return unless @reach_selection

        ids = @reach_selection.test_ids(adapter.tests, framework: @framework, paths: @test_files, rails: @rails,
                                                       load_reached: load_reached & probe_table.keys)
        result = probe_baseline(adapter, probe_table, ids, allow_failure: true)
        unless result["success"] && result.fetch("tests").keys == ids && !result.dig("probe", "load_reached").intersect?(probe_table.keys)
          raise ReachSelection::Unusable, "the selected baseline failed or had incomplete observations"
        end

        @metrics["baseline_reach_map"] = true
        result
      rescue ReachSelection::Unusable => e
        raise RetryFull, e.message if @narrowed_test_files

        @warnings << "reach-map fallback: #{e.message}"
        nil
      end

      def probe_baseline(adapter, probe_table, ids, allow_failure: false, record_outcomes: false)
        run_baseline(allow_failure: allow_failure) do
          probe = Probe.new(probe_table, samples: @config[:samples])
          R.probe = probe
          result = run_baseline_tests(adapter, ids, record_outcomes:)
          result.merge("probe" => probe.snapshot)
        end
      end

      def run_baseline(allow_failure: false, &)
        result = Child.call(timeout_ms: 60_000 + (@rails&.worker_timeout_ms || 0), &)
        return result if result["success"] || allow_failure

        failures = result["failures"] || [result["error"] || result["status"]]
        messages = failures.map { |failure| failure.is_a?(Hash) ? failure["message"] : failure }
        raise BaselineFailure, "baseline failed: #{messages.join('; ')}"
      end

      def run_baseline_tests(adapter, test_ids, record_outcomes: false)
        run = if record_outcomes
                -> { BaselineStability.capture { adapter.run(test_ids, record_outcomes: true) } }
              else
                -> { adapter.run(test_ids) }
              end
        @rails ? @rails.with_worker(0, &run) : run.call
      end

      def prepare_rails_workers(count, observer:)
        return unless @rails

        if observer
          observer.capture { @rails.prepare_workers(count) }
        else
          @rails.prepare_workers(count)
        end
      end

      def relative(path)
        Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(Dir.pwd)).to_s
      end
    end
  end
end
