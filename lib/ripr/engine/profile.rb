# frozen_string_literal: true

require_relative "../snapshot"

module Ripr
  module Engine
    class Profile
      def initialize
        @phases = %w[plan instrument boot baseline mutation report].to_h { |phase| [phase, 0.0] }
        @mutations = []
        @replays = []
        @diagnoses = []
        @probe_skipped = 0
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def phase(name, started)
        @phases[name] += (now - started) * 1000
      end

      def skip_mutation(status)
        @probe_skipped += 1 if %w[not_reached not_infected].include?(status)
      end

      def record_mutation(mutant, outcome, duration)
        @mutations << attempt(mutant, outcome, duration)
      end

      def record_replay(mutant, outcome, duration)
        @replays << attempt(mutant, outcome, duration)
      end

      def record_diagnosis(mutant, outcome, duration)
        @diagnoses << attempt(mutant, outcome, duration)
      end

      def write(directory, selected, metrics, baseline)
        baseline_total = baseline ? baseline.fetch("tests").size : 0
        baseline_run = metrics.fetch("baseline_tests_run")
        baseline_reused = baseline_total - baseline_run
        cached = metrics.fetch("reused")
        skipped = @probe_skipped + cached
        eligible = @mutations.length + skipped
        Snapshot.new(File.join(directory, "profile.json")).write(
          "schema" => "ripr.profile/v1",
          "phases_ms" => @phases.merge("plan" => @phases.fetch("plan") - @phases.fetch("instrument")),
          "baseline" => { "tests_run" => baseline_run, "tests_reused" => baseline_reused,
                          "cache_hit_fraction" => fraction(baseline_reused, baseline_total) },
          "mutations" => execution(@mutations).merge("selected" => selected, "cached" => cached, "probe_skipped" => @probe_skipped,
                                                     "cache_hit_fraction" => fraction(cached, eligible),
                                                     "skipped_fraction" => fraction(skipped, eligible)),
          "verification" => execution(@replays), "diagnosis" => execution(@diagnoses)
        )
      end

      private

      def attempt(mutant, outcome, duration)
        { "id" => mutant.fetch("id"), "duration_ms" => duration, "tests_run" => outcome["tests"]&.size }
      end

      def execution(attempts)
        durations = attempts.map { |entry| entry.fetch("duration_ms") }.sort
        counts = attempts.filter_map { |entry| entry.fetch("tests_run") }
        { "attempted" => attempts.length, "tests_run" => counts.sum, "unknown_test_counts" => attempts.length - counts.length,
          "tests_per_mutation" => fraction(counts.sum, counts.length), "attempts" => attempts.sort_by { |entry| entry.fetch("id") },
          "latency_ms" => { "p50" => percentile(durations, 0.5), "p95" => percentile(durations, 0.95) } }
      end

      def percentile(sorted, fraction)
        sorted[(sorted.length * fraction).ceil - 1]
      end

      def fraction(value, total)
        value.fdiv(total) if total.positive?
      end
    end
  end
end
