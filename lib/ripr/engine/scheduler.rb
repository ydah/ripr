# frozen_string_literal: true

require_relative "child"

module Ripr
  module Engine
    class Scheduler
      def initialize(config, baseline, table, cache, warnings:, metrics:)
        @config = config
        @baseline = baseline
        @table = table
        @cache = cache
        @warnings = warnings
        @metrics = metrics
      end

      def call(selected, adapter, &progress)
        probe = @baseline.fetch("probe")
        ready = []
        results = selected.filter_map do |mutant|
          reach = probe.fetch("reach").fetch(mutant.fetch("site"), [])
          infect = probe.fetch("infect").fetch(mutant.fetch("id"), [])
          unknown_reach = probe.fetch("load_reached").include?(mutant.fetch("site"))
          status = if mutant["accepted"] then "accepted"
                   elsif mutant["invalid"] then "invalid"
                   elsif reach.empty? && !unknown_reach then "not_reached"
                   elsif mutant["mode"] == "value" && infect.empty? && !unknown_reach
                     "not_infected"
                   end
          data = mutant.merge("load_reached" => unknown_reach,
                              "observed" => probe.fetch("samples").fetch(mutant.fetch("site"), []),
                              "covering_tests" => reach.filter_map { |id| @baseline.fetch("tests")[id]&.merge("id" => id) })
          cached = @cache.result_for(mutant) unless %w[accepted invalid].include?(status)
          verify = %w[not_reached not_infected].include?(status) &&
                   (!@config[:only].empty? || (@config[:verify_not_infected] && status == "not_infected"))
          if cached
            @metrics["reused"] += 1
            cached.merge("load_reached" => unknown_reach)
          elsif status && !verify
            data.merge("status" => status)
          else
            ids = if unknown_reach
                    @baseline.fetch("tests").keys
                  else
                    (mutant["mode"] == "value" ? infect : reach)
                  end
            ids = reach if ids.empty?
            ids = @baseline.fetch("tests").keys if ids.empty?
            ids.sort_by! { |id| @baseline.fetch("tests").fetch(id).fetch("duration_ms") }
            ready << data.merge("test_ids" => ids, "verification_status" => verify ? status : nil)
            nil
          end
        end
        cost = lambda do |mutant|
          mutant.fetch("test_ids").sum { |id| @baseline.fetch("tests").fetch(id).fetch("duration_ms") }
        end
        timeout = ->(mutant) { @config[:timeout].fetch("base_ms") + (@config[:timeout].fetch("factor") * cost.call(mutant)) }
        completed = Child.batch(ready.sort_by(&cost), jobs: @config[:jobs], timeout: timeout, on_complete: progress) do |mutant|
          site_ids = @table.fetch(mutant.fetch("site"))
          R.activate(mutant.fetch("site"), site_ids.index(mutant.fetch("id")) + 1)
          adapter.run(mutant.fetch("test_ids"), fail_fast: true)
        end
        completed.each do |mutant, outcome|
          status = outcome["status"] || (outcome["success"] ? "not_detected" : "killed")
          verification = mutant["verification_status"]
          if verification
            status = verification if outcome["success"]
            @warnings << "verification discrepancy #{mutant.fetch('id')}: expected #{verification}, got killed" if status == "killed"
          end
          failure = outcome["failures"]&.first
          result = mutant.except("test_ids", "verification_status").merge("status" => status,
                                                                          "killed_by" => failure.is_a?(Hash) ? failure["id"] : failure,
                                                                          "error" => outcome["error"])
          result["verified"] = true if verification
          results << result
        end
        results.sort_by { |mutant| mutant.fetch("full_id") }
      end
    end
  end
end
