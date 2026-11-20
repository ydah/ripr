# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "../snapshot"
require_relative "../core/reuse_planner"

module Ripr
  module Engine
    class ResultCache
      attr_reader :baseline_env_hash, :source_hash, :test_hashes, :previous, :graph

      def initialize(config, sources:, test_files:, framework:, mutants:, test_ids:, probe_sites:, graph: nil, load_dependencies: nil)
        @config = config
        @mutants = mutants
        @snapshot = Snapshot.new
        @previous = config[:full] || config[:boot] || config[:rails] ? {} : @snapshot.read
        @source_hash = digest(sources.sort.to_h.transform_values { |source| Digest::SHA256.hexdigest(source) })
        @test_hashes = test_files.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
        lockfiles = %w[Gemfile.lock .rspec .rspec-local]
        if framework == "rspec"
          lockfiles << File.join(Dir.home, ".rspec")
          lockfiles << File.join(File.expand_path(ENV.fetch("XDG_CONFIG_HOME", "~/.config")), "rspec", "options")
        end
        lockfiles << Bundler.default_lockfile.to_s if defined?(Bundler) && ENV["BUNDLE_GEMFILE"]
        auxiliary = (Dir.glob("{test,spec}/**/*") + lockfiles).uniq.select do |path|
          File.file?(path) && !test_files.include?(path)
        end
        dependencies = auxiliary.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
        settings = config.to_h.slice(:operators, :arid_callees, :tests, :samples, :seed, :static)
        context = [VERSION, RUBY_ENGINE, RUBY_VERSION, RUBY_PLATFORM, Dir.pwd, Prism::VERSION, framework,
                   settings, dependencies, probe_sites.sort, ENV.fetch("RIPR_LOADER", nil), ENV.fetch("SPEC_OPTS", nil)]
        execution = [@test_hashes, test_ids.sort, config[:timeout], config[:jobs],
                     config[:verify_not_infected], config[:verify_killed], config[:call_graph_reuse], config[:typecheck]]
        @baseline_env_hash = digest([context, @source_hash])
        @env_hash = digest([@baseline_env_hash, execution])
        if graph&.structure_hash && (load_signature = graph.signature(load_dependencies))
          @graph = graph
          @graph_context = digest([context, execution, graph.structure_hash, load_signature.sort])
        end
      end

      def result_for(mutant, probe: nil)
        return if @config[:full] || !@config[:only].empty?

        record = @previous.fetch("mutants", {})[mutant.fetch("full_id")]
        return if @config[:verify_not_infected] && record.is_a?(Hash) && record["status"] == "not_infected"
        return if @config[:verify_killed] && record.is_a?(Hash) && record["status"] == "killed"
        return unless Core::ReusePlanner.reusable?(record, mutant, env_hash: @env_hash, test_hashes: @test_hashes) ||
                      reusable_graph?(record, mutant, probe)
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
          record = result.merge("env_hash" => @env_hash, "tests" => @test_hashes.slice(*files), "recorded_at" => Time.now.utc.iso8601)
          if @graph && result["dependency_hashes"]
            record["graph_context"] = @graph_context
            record["observation_hash"] = observation_hash(result, baseline.fetch("probe"))
          end
          records[result.fetch("full_id")] = record
        end
        @snapshot.write("version" => Snapshot::VERSION, "env_hash" => @env_hash, "source_hash" => @source_hash,
                        "test_hashes" => @test_hashes, "mutants" => records, "baseline" => baseline, "metrics" => metrics)
      end

      private

      def reusable_graph?(record, mutant, probe)
        return false unless @graph && probe && record.is_a?(Hash) && record["graph_context"] == @graph_context
        return false unless %w[killed not_detected].include?(record["status"])
        return false unless record["full_id"] == mutant["full_id"] && record["method_hash"] == mutant["method_hash"]
        return false if probe.fetch("load_reached").include?(mutant.fetch("site"))

        dependencies = record["dependency_hashes"]
        dependencies.is_a?(Hash) && !dependencies.empty? && @graph.signature(dependencies.keys) == dependencies &&
          record["observation_hash"] == observation_hash(mutant, probe)
      end

      def observation_hash(mutant, probe)
        site = mutant.fetch("site")
        digest([probe.fetch("reach").fetch(site, []).sort, probe.fetch("infect").fetch(mutant.fetch("id"), []).sort,
                probe.fetch("samples").fetch(site, []), probe.fetch("load_reached").include?(site)])
      end

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
