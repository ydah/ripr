# frozen_string_literal: true

require_relative "child"

module Ripr
  module Engine
    class Scheduler
      def initialize(config, baseline, table, cache, warnings:, metrics:, rails: nil, static_run: nil, profile: nil)
        @config = config
        @baseline = baseline
        @table = table
        @cache = cache
        @warnings = warnings
        @metrics = metrics
        @rails = rails
        @static_run = static_run
        @profile = profile
      end

      def call(selected, adapter, &progress)
        results, ready = classify(selected)
        ready.sort_by! { |mutant| estimated_cost(mutant) }
        timeout = method(:deadline)
        completed = Child.batch(ready, jobs: @config[:jobs], timeout: timeout, on_complete: progress,
                                       on_result: @profile&.method(:record_mutation)) do |mutant, slot|
          execute(mutant, slot, adapter)
        end
        originals = @config[:verify_killed] ? verify_kills(completed, adapter, timeout) : {}
        results.concat(record_results(completed, originals)).sort_by { |mutant| mutant.fetch("full_id") }
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

      def record_results(completed, originals)
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
          result
        end
      end

      def execute(mutant, slot, adapter, original: false)
        tests = mutant.fetch("test_ids")
        run = lambda do
          if mutant["static"]
            @static_run.call(original ? nil : mutant.fetch("full_id"), tests)
          else
            unless original
              site = mutant.fetch("site")
              R.activate(site, @table.fetch(site).index(mutant.fetch("id")) + 1)
            end
            if @cache.graph && !original
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
    end
  end
end
