# frozen_string_literal: true

require "rspec"
require "stringio"
require_relative "../runtime"

module Ripr
  module Integration
    class RSpec
      def initialize(test_files, seed: 0, seed_random: false)
        @test_files = test_files.map { |path| File.expand_path(path) }
        @seed = seed
        @seed_random = seed_random
        @executed = {}
      end

      def load
        return self if @loaded

        ::RSpec::Core::Runner.disable_autorun!
        adapter = self
        ::RSpec.configure do |config|
          config.around(:each) { |example| adapter.record(example) }
        end
        options = ::RSpec::Core::ConfigurationOptions.new(["--seed", @seed.to_s, "--format", "progress", *@test_files])
        @runner = ::RSpec::Core::Runner.new(options)
        @output = StringIO.new
        @runner.setup(@output, @output)
        world = ::RSpec.world
        @load_failed = world.wants_to_quit || world.non_example_failure
        @groups = world.all_example_groups
        @examples = @groups.flat_map { |group| world.filtered_examples[group] }
        @loaded = true
        self
      end

      def tests
        @examples.map do |example|
          { "id" => example.id, "file" => File.expand_path(example.metadata.fetch(:file_path)),
            "line" => example.metadata.fetch(:line_number) }
        end
      end

      def run(ids = nil, fail_fast: false, record_outcomes: false)
        return { "success" => false, "tests" => {}, "failures" => [{ "message" => @output.string }] } if @load_failed

        ids ||= @examples.map(&:id)
        unknown = ids - @examples.map(&:id)
        raise ArgumentError, "unknown test IDs: #{unknown.join(', ')}" unless unknown.empty?
        return { "success" => false, "tests" => {}, "failures" => [{ "message" => "No tests selected" }] } if ids.empty?

        @executed = {}
        ::RSpec.configuration.fail_fast = fail_fast
        ::RSpec.world.wants_to_quit = false
        ::RSpec.world.non_example_failure = false
        @groups.each do |group|
          ::RSpec.world.filtered_examples[group] = @examples.select { |example| example.example_group == group && ids.include?(example.id) }
        end
        ranks = ids.each_with_index.to_h
        ordering = lambda do |items|
          items.sort_by do |item|
            examples = item.respond_to?(:id) ? [item] : item.descendant_filtered_examples
            examples.map { |example| ranks.fetch(example.id, ids.length) }.min || ids.length
          end
        end
        ::RSpec.configuration.ordering_registry.register(:global, ::RSpec::Core::Ordering::Custom.new(ordering))
        @outcomes = record_outcomes ? {} : nil
        ::RSpec.configuration.reporter.register_listener(self, :example_finished) if record_outcomes
        srand(@seed) if @seed_random
        status = @runner.run_specs(::RSpec.world.ordered_example_groups)
        failures = @examples.filter_map do |example|
          next unless (@outcomes || @executed).key?(example.id) && example.execution_result.status == :failed

          { "id" => example.id, "message" => example.execution_result.exception.message }
        end
        if !status.zero? && (failures.empty? || (record_outcomes && ::RSpec.world.non_example_failure))
          failures << { "message" => @output.string }
        end
        result = { "success" => status.zero?, "tests" => @executed, "failures" => failures }
        result["outcomes"] = @outcomes if record_outcomes
        result
      end

      def example_finished(notification)
        example = notification.example
        @outcomes[example.id] = example.execution_result.status.to_s if @outcomes
      end

      def record(example)
        R.current_test = example.id
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        example.run
      ensure
        @executed[example.id] = { "file" => File.expand_path(example.metadata.fetch(:file_path)),
                                  "line" => example.metadata.fetch(:line_number),
                                  "duration_ms" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000 }
        R.current_test = nil
      end
    end
  end
end
