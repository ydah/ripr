# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "../snapshot"
require_relative "../core/reuse_planner"

module Ripr
  module Engine
    class ResultCache
      attr_reader :baseline_env_hash, :source_hash, :test_hashes, :previous

      def initialize(config, sources:, test_files:, framework:, mutants:)
        @config = config
        @mutants = mutants
        @snapshot = Snapshot.new
        @previous = config[:full] ? {} : @snapshot.read
        @source_hash = digest(sources.sort.to_h.transform_values { |source| Digest::SHA256.hexdigest(source) })
        @test_hashes = test_files.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
        auxiliary = (Dir.glob("{test,spec}/**/*") + %w[Gemfile.lock .rspec]).uniq.select do |path|
          File.file?(path) && !test_files.include?(path)
        end
        dependencies = auxiliary.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
        settings = config.to_h.slice(:operators, :arid_callees, :tests, :samples, :seed)
        @baseline_env_hash = digest([VERSION, RUBY_ENGINE, RUBY_VERSION, Prism::VERSION, framework, settings, @source_hash, dependencies])
        @env_hash = digest([@baseline_env_hash, @test_hashes, config[:timeout], config[:jobs], config[:verify_not_infected]])
      end

      def result_for(mutant)
        return if @config[:full] || !@config[:only].empty?

        record = @previous.fetch("mutants", {})[mutant.fetch("full_id")]
        return if @config[:verify_not_infected] && record.is_a?(Hash) && record["status"] == "not_infected"
        return unless Core::ReusePlanner.reusable?(record, mutant, env_hash: @env_hash, test_hashes: @test_hashes)
        return unless valid_record?(record)

        record.merge(mutant).merge("reused" => true)
      end

      def write(results, baseline, metrics)
        current = @mutants.to_h { |mutant| [mutant.fetch("full_id"), mutant] }
        records = @previous.fetch("mutants", {}).select do |id, record|
          mutant = current[id]
          mutant && valid_record?(record) && record["env_hash"] == @env_hash && record["method_hash"] == mutant["method_hash"]
        end
        results.each do |result|
          files = result.fetch("covering_tests", []).map { |test| test.fetch("file") }
          records[result.fetch("full_id")] = result.merge("env_hash" => @env_hash, "tests" => @test_hashes.slice(*files),
                                                          "recorded_at" => Time.now.utc.iso8601)
        end
        @snapshot.write("version" => 1, "env_hash" => @env_hash, "source_hash" => @source_hash, "test_hashes" => @test_hashes,
                        "mutants" => records, "baseline" => baseline, "metrics" => metrics)
      end

      private

      def valid_record?(record)
        return false unless record.is_a?(Hash) && samples?(record["observed"]) && record["covering_tests"].is_a?(Array)

        record["covering_tests"].all? do |test|
          test.is_a?(Hash) && test["id"].is_a?(String) && !test["id"].empty? &&
            test["file"].is_a?(String) && !test["file"].empty? && test["line"].is_a?(Integer) && test["line"].positive?
        end
      end

      def samples?(samples)
        samples.is_a?(Array) && samples.length <= 3 && samples.all? do |pair|
          pair.is_a?(Array) && pair.length == 2 && pair.all? do |value|
            value.nil? || [true, false].include?(value) || value.is_a?(String) || (value.is_a?(Numeric) && value.finite?)
          end
        end
      end

      def digest(value)
        Digest::SHA256.hexdigest(JSON.generate(value))
      end
    end
  end
end
