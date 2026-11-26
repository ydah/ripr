# frozen_string_literal: true

module Ripr
  module Engine
    class BaselineStability
      RIPR_LIB = "#{File.expand_path('..', __dir__)}/".freeze
      OUTCOME_CHANGED = "outcome changed"
      RANDOM_OWNERS = [Kernel, Kernel.singleton_class, Random.singleton_class, Random.instance_method(:rand).owner,
                       Random::Formatter].freeze

      attr_reader :attempted_tests

      def initialize(runs, warnings)
        @runs = runs
        @warnings = warnings
        @attempted_tests = 0
        @quarantine = []
      end

      def call(&)
        baseline, changes, dependencies = repeat(nil, &)
        check_failures(baseline, changes)
        return runnable_baseline(baseline) if changes.empty?

        @quarantine = changes.sort.map do |id, reasons|
          suspects = dependencies.fetch(id, [])
          hint = " (observed #{suspects.sort.join(' and ')} calls)" unless suspects.empty?
          "quarantined #{id}: #{reasons.join(', ')}#{hint}"
        end
        @warnings.concat(@quarantine)
        retained = baseline.fetch("outcomes").keys - changes.keys
        fail_baseline("no stable tests remain") if retained.empty?

        baseline, changes = repeat(retained, &)
        check_failures(baseline, {})
        fail_baseline("retained tests changed across runs: #{changes.keys.sort.join(', ')}") unless changes.empty?

        runnable_baseline(baseline)
      end

      def self.capture(&)
        project = "#{Dir.pwd}/"
        harness = %w[minitest rspec-core].filter_map { |gem| Gem.loaded_specs[gem]&.full_gem_path }.map { |path| "#{path}/" }
        harness << RIPR_LIB
        dependencies = {}
        trace = TracePoint.new(:call, :c_call) do |event|
          dependency = dependency(event)
          next unless dependency && (id = R.current_test)

          path = event.event == :c_call ? event.path : caller_locations(2, 1).first&.absolute_path
          next unless path

          path = File.expand_path(path)
          next unless path.start_with?(project) && !path.start_with?(*harness)

          calls = (dependencies[id] ||= [])
          calls << dependency unless calls.include?(dependency)
        end
        trace.enable(&).merge("dependencies" => dependencies)
      end

      def self.dependency(event)
        case event.method_id
        when :now
          "clock" if Value::IDENTITY.bind_call(event.defined_class, Time.singleton_class)
        when :clock_gettime
          "clock" if Value::IDENTITY.bind_call(event.defined_class, Process.singleton_class)
        when :rand, :random_number, :new_seed
          "random" if RANDOM_OWNERS.any? { |owner| Value::IDENTITY.bind_call(owner, event.defined_class) }
        end
      end
      private_class_method :dependency

      private

      def repeat(ids, &)
        baseline = attempt(ids, &)
        observed = observations(baseline)
        changed = Hash.new { |tests, id| tests[id] = [] }
        dependencies = baseline.fetch("dependencies").dup
        (@runs - 1).times do
          result = attempt(ids, &)
          compare(observed, observations(result), changed)
          dependencies.merge!(result.fetch("dependencies")) { |_, before, after| before | after }
        end
        [baseline, changed, dependencies]
      end

      def attempt(ids)
        result = yield ids
        failures = result.fetch("failures", [])
        unless result.key?("outcomes") && failures.all? { |failure| failure.key?("id") } &&
               (result["success"] || !failures.empty?)
          problems = failures.map { |failure| failure.fetch("message") }
          fail_baseline((problems + [result["error"] || result["status"]]).compact.join("\n"))
        end
        @attempted_tests += result.fetch("tests").length
        result
      end

      def observations(result)
        probe = result.fetch("probe")
        { OUTCOME_CHANGED => result.fetch("outcomes"),
          "test execution changed" => result.fetch("tests").transform_values { true },
          "mutation reach changed" => by_test(probe.fetch("reach")),
          "mutation infection changed" => by_test(probe.fetch("infect")),
          "load reach" => probe.fetch("load_reached").sort }
      end

      def by_test(memberships)
        memberships.each_with_object({}) do |(subject, ids), result|
          ids.each { |id| (result[id] ||= {})[subject] = true }
        end
      end

      def compare(before, after, changed)
        fail_baseline("unattributed mutation reach changed across runs") unless before.fetch("load reach") == after.fetch("load reach")

        order = before.fetch(OUTCOME_CHANGED).keys
        next_order = after.fetch(OUTCOME_CHANGED).keys
        fail_baseline("test execution order changed across runs") unless (order & next_order) == (next_order & order)

        before.each do |reason, entries|
          next if reason == "load reach"

          current = after.fetch(reason)
          (entries.keys | current.keys).each do |id|
            changed[id] |= [reason] unless entries[id] == current[id]
          end
        end
      end

      def check_failures(baseline, changed)
        failures = baseline.fetch("failures").reject { |failure| changed.fetch(failure.fetch("id"), []).include?(OUTCOME_CHANGED) }
        return if failures.empty?

        fail_baseline(failures.map { |failure| "#{failure.fetch('id')}: #{failure.fetch('message')}" }.join("\n"))
      end

      def runnable_baseline(baseline)
        outcomes = baseline.fetch("outcomes")
        fail_baseline("no stable tests remain") unless baseline.fetch("tests").any? { |id, _| outcomes[id] == "passed" }

        baseline
      end

      def fail_baseline(message)
        raise BaselineFailure, ["baseline failed: #{message}", *@quarantine].join("\n")
      end
    end
  end
end
