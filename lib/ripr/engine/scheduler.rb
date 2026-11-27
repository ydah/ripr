# frozen_string_literal: true

require_relative "child"
require_relative "implicit_returns"
require_relative "method_exits"

module Ripr
  module Engine
    class Scheduler
      Trial = Data.define(:mutant, :targets, :return_sites)
      private_constant :Trial

      def initialize(config, baseline, table, cache, targets:, warnings:, metrics:, rails: nil, static_run: nil, profile: nil)
        @config = config
        @baseline = baseline
        @table = table
        @cache = cache
        @targets = targets
        @warnings = warnings
        @metrics = metrics
        @rails = rails
        @static_run = static_run
        @profile = profile
      end

      def call(selected, adapter, &progress)
        results, ready = classify(selected)
        @static_run&.prepare if @config[:static] && ready.count { |mutant| mutant["static"] } > 1
        ready.sort_by! { |mutant| estimated_cost(mutant) }
        timeout = method(:deadline)
        completed = Child.batch(ready, jobs: @config[:jobs], timeout: timeout, on_complete: progress,
                                       on_result: @profile&.method(:record_mutation)) do |mutant, slot|
          execute(mutant, slot, adapter)
        end
        verify = @config[:verify_killed] || @config[:baseline_runs] > 1
        originals = verify ? verify_kills(completed, adapter, timeout) : {}
        diagnoses = diagnose(completed, adapter)
        results.concat(record_results(completed, originals, diagnoses)).sort_by { |mutant| mutant.fetch("full_id") }
      ensure
        @static_run&.close
      end

      def shard_costs(selected)
        _, ready = classify(selected)
        costs = ready.to_h { |mutant| [mutant.fetch("full_id"), estimated_cost(mutant)] }
        selected.to_h { |mutant| [mutant.full_id, costs.fetch(mutant.full_id, 0)] }
      end

      private

      def classify(selected)
        probe = @baseline.fetch("probe")
        tests = @baseline.fetch("tests")
        test_order = Hash.new { |order, id| order[id] = [tests.fetch(id).fetch("duration_ms"), id] }
        ready = []
        results = selected.filter_map do |mutant|
          reach = probe.fetch("reach").fetch(mutant.site, [])
          infect = probe.fetch("infect").fetch(mutant.id, [])
          unknown_reach = probe.fetch("load_reached").include?(mutant.site)
          status = if mutant.accepted then "accepted"
                   elsif mutant.invalid then "invalid"
                   elsif reach.empty? && !unknown_reach then "not_reached"
                   elsif mutant.mode == "value" && infect.empty? && !unknown_reach
                     "not_infected"
                   end
          data = mutant.to_record.merge("load_reached" => unknown_reach,
                                        "observed" => probe.fetch("samples").fetch(mutant.site, []),
                                        "covering_tests" => reach.filter_map { |id| tests[id]&.merge("id" => id) })
          cached = @cache.result_for(data, probe: probe) unless %w[accepted invalid].include?(status)
          verify = %w[not_reached not_infected].include?(status) &&
                   (!@config[:only].empty? || (@config[:verify_not_infected] && status == "not_infected"))
          if cached
            @metrics["reused"] += 1
            cached
          elsif status && !verify
            @profile&.skip_mutation(status)
            data.merge("status" => status)
          else
            ids = if unknown_reach
                    @baseline.fetch("tests").keys
                  else
                    (mutant.mode == "value" ? infect : reach)
                  end
            ids = reach if ids.empty?
            ids = @baseline.fetch("tests").keys if ids.empty?
            killer = @cache.previous_killer(data, ids, tests)
            ids = ids.sort_by { |id| test_order[id] }
            ids.unshift(ids.delete(killer)) if killer && killer != ids.first
            ready << data.merge("test_ids" => ids, "verification_status" => verify ? status : nil)
            nil
          end
        end
        [results, ready]
      end

      def estimated_cost(mutant)
        mutant.fetch("test_ids").sum { |id| @baseline.fetch("tests").fetch(id).fetch("duration_ms") }
      end

      def deadline(mutant)
        boot_ms = mutant["static"] ? 2 * @static_run.boot_ms : 0
        @config[:timeout].fetch("base_ms") + (@config[:timeout].fetch("factor") * estimated_cost(mutant)) +
          boot_ms + (@rails&.worker_timeout_ms || 0)
      end

      def record_results(completed, originals, diagnoses)
        completed.map do |mutant, outcome|
          status = outcome["status"] || (outcome["success"] ? "not_detected" : "killed")
          failure = outcome["failures"]&.first
          error = outcome["error"]
          if (original = originals[mutant]) && !original["success"]
            status = "error"
            failure = nil
            detail = original.dig("failures", 0, "message") || original["error"] || original["status"]
            error = "could not verify kill #{mutant.fetch('id')} on original code#{" (#{detail})" if detail}"
            @warnings << error
          end
          verification = mutant["verification_status"]
          if verification
            status = verification if outcome["success"]
            @warnings << "verification discrepancy #{mutant.fetch('id')}: expected #{verification}, got killed" if status == "killed"
          end
          result = mutant.except("test_ids", "verification_status").merge("status" => status,
                                                                          "killed_by" => failure.is_a?(Hash) ? failure["id"] : failure,
                                                                          "error" => error)
          result["verified"] = true if verification
          result["dependency_hashes"] = outcome["dependency_hashes"] if outcome["dependency_hashes"]
          result.merge!(diagnoses.fetch(mutant.fetch("full_id"), {}))
          result
        end
      end

      def execute(mutant, slot, adapter, original: false, targets: nil, return_sites: [])
        tests = mutant.fetch("test_ids")
        run = lambda do
          if mutant["static"]
            @static_run.call(original ? nil : mutant.fetch("full_id"), tests)
          else
            unless original
              site = mutant.fetch("site")
              R.activate(site, @table.fetch(site).index(mutant.fetch("id")) + 1)
            end
            if targets
              (result, exits), returns = ImplicitReturns.observe(return_sites, tests) do
                MethodExits.observe(targets) { adapter.run(tests, fail_fast: true) }
              end
              result.merge("exits" => exits, "implicit_returns" => returns)
            elsif @cache.graph && !original
              result, dependencies = @cache.graph.trace { adapter.run(tests, fail_fast: true) }
              result.merge("dependency_hashes" => @cache.graph.signature(dependencies))
            else
              adapter.run(tests, fail_fast: true)
            end
          end
        end
        @rails ? @rails.with_worker(slot, fresh_boot: mutant["static"] == true, &run) : run.call
      end

      def verify_kills(completed, adapter, timeout)
        killed = completed.filter_map { |mutant, result| mutant if !result["status"] && !result["success"] }
        Child.batch(killed, jobs: @config[:jobs], timeout: timeout, on_result: @profile&.method(:record_replay)) do |mutant, slot|
          execute(mutant, slot, adapter, original: true)
        end.to_h
      end

      def diagnose(completed, adapter)
        survivors = completed.filter_map do |mutant, outcome|
          if outcome["success"] && !outcome["status"] && !mutant["static"] && !mutant["load_reached"] && !mutant["verification_status"]
            ids = mutant.fetch("test_ids") | mutant.fetch("covering_tests").map { |test| test.fetch("id") }
            mutant.merge("test_ids" => ids)
          end
        end
        return {} if survivors.empty?

        targets = @targets.call.slice(*survivors.map { |mutant| mutant.fetch("subject") }.uniq)
        jobs = survivors.select { |mutant| targets.key?(mutant.fetch("subject")) || ImplicitReturns.site(mutant) }
        originals = stable_exits(jobs, targets, adapter)
        trials = jobs.filter_map do |mutant|
          baseline = originals[mutant.fetch("test_ids")]
          next unless baseline

          subject = mutant.fetch("subject")
          site = ImplicitReturns.site(mutant)
          method_targets = baseline.fetch("exits").key?(subject) ? targets.slice(subject) : {}
          return_sites = baseline.fetch("implicit_returns").key?(site) ? [site] : []
          Trial.new(mutant, method_targets, return_sites) unless method_targets.empty? && return_sites.empty?
        end
        observe_trials(trials, adapter, original: false).each_with_object({}) do |(trial, outcome), diagnoses|
          mutant = trial.mutant
          ids = mutant.fetch("test_ids")
          baseline = originals.fetch(ids)
          next unless outcome["success"] && outcome.fetch("tests").keys == baseline.fetch("order")

          subject = mutant.fetch("subject")
          diagnosis = MethodExits.compare(baseline.fetch("exits")[subject], outcome.fetch("exits")[subject], ids)
          if !diagnosis && (site = trial.return_sites.first)
            diagnosis = ImplicitReturns.compare(baseline.fetch("implicit_returns")[site], outcome.fetch("implicit_returns")[site], ids)
          end
          diagnoses[mutant.fetch("full_id")] = diagnosis if diagnosis
        end
      end

      def stable_exits(jobs, targets, adapter)
        trials = jobs.group_by { |mutant| mutant.fetch("test_ids") }.values.map do |group|
          subjects = group.map { |mutant| mutant.fetch("subject") }
          Trial.new(group.first, targets.slice(*subjects), group.filter_map(&ImplicitReturns.method(:site)))
        end
        first = observe_trials(trials, adapter, original: true).to_h
        repeated = trials.select do |trial|
          outcome = first.fetch(trial)
          outcome["success"] && outcome.fetch("tests").keys.sort == trial.mutant.fetch("test_ids").sort
        end
        observe_trials(repeated, adapter, original: true).each_with_object({}) do |(trial, outcome), stable|
          before = first.fetch(trial)
          order = before.fetch("tests").keys
          next unless outcome["success"] && outcome.fetch("tests").keys == order

          exits = MethodExits.stable(before.fetch("exits"), outcome.fetch("exits"))
          returns = ImplicitReturns.stable(before.fetch("implicit_returns"), outcome.fetch("implicit_returns"))
          stable[trial.mutant.fetch("test_ids")] = { "exits" => exits, "implicit_returns" => returns, "order" => order }
        end
      end

      def observe_trials(trials, adapter, original:)
        # Rails exposes the slot to tests through TEST_ENV_NUMBER.
        jobs = @rails ? 1 : @config[:jobs]
        timeout = ->(trial) { deadline(trial.mutant) }
        on_result = ->(trial, outcome, elapsed) { @profile.record_diagnosis(trial.mutant, outcome, elapsed) } if @profile
        Child.batch(trials, jobs: jobs, timeout: timeout, on_result:) do |trial, slot|
          execute(trial.mutant, slot, adapter, original: original, targets: trial.targets, return_sites: trial.return_sites)
        end
      end
    end
  end
end
