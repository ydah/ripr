# frozen_string_literal: true

require "minitest"
require_relative "../runtime"

module Ripr
  module Integration
    class Minitest
      def initialize(test_files, seed: 0)
        @test_files = test_files.map { |path| File.expand_path(path) }
        @seed = seed
        @cases = {}
      end

      def load
        return self if @loaded

        ::Minitest.singleton_class.prepend(Module.new do
          def autorun; end
        end)
        existing = ::Minitest::Runnable.runnables.dup
        @test_files.each { |file| require file }
        ::Minitest.seed = @seed
        srand(@seed)
        (::Minitest::Runnable.runnables - existing).each do |klass|
          klass.runnable_methods.sort.each { |method| @cases["#{klass}##{method}"] = [klass, method] }
        end
        @loaded = true
        self
      end

      def tests
        @cases.map do |id, (klass, method)|
          file, line = klass.instance_method(method).source_location
          { "id" => id, "file" => File.expand_path(file), "line" => line }
        end
      end

      def run(ids = nil, fail_fast: false)
        ids ||= @cases.keys.sort
        unknown = ids - @cases.keys
        raise ArgumentError, "unknown test IDs: #{unknown.join(', ')}" unless unknown.empty?

        result = { "success" => !ids.empty?, "tests" => {}, "failures" => [] }
        result["failures"] << { "message" => "No tests selected" } if ids.empty?
        metadata = tests.to_h { |test| [test.fetch("id"), test] }
        srand(@seed)
        ids.each do |id|
          klass, method = @cases.fetch(id)
          R.current_test = id
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          test = if ::Minitest.respond_to?(:run_one_method)
                   ::Minitest.run_one_method(klass, method)
                 else
                   klass.new(method).run
                 end
          duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
          result["tests"][id] = metadata.fetch(id).except("id").merge("duration_ms" => duration)
          next if test.passed? || test.skipped?

          result["success"] = false
          result["failures"] << { "id" => id, "message" => test.failures.map(&:message).join("\n") }
          break if fail_fast
        ensure
          R.current_test = nil
        end
        result
      end
    end
  end
end
