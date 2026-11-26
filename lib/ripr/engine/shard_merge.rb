# frozen_string_literal: true

require "json"
require_relative "shard_plan"
require_relative "../core/classifier"

module Ripr
  module Engine
    class ShardMerge
      def self.call(plan, digest, artifact_paths)
        new(plan, digest).call(artifact_paths)
      end

      def initialize(plan, digest)
        @digest = digest
        @buckets = plan.fetch("shards")
        @sources, @fingerprints = plan.fetch("identity").values_at("sources", "mutation_fingerprints")
        @tests, probe = plan.fetch("baseline").values_at("tests", "probe")
        unless @sources.is_a?(Hash) && @fingerprints.is_a?(Hash) && @tests.is_a?(Hash) && probe.is_a?(Hash)
          raise ArgumentError, "invalid shard plan metadata"
        end

        @reach, @samples, @load_reached = probe.values_at("reach", "samples", "load_reached")
        unless @reach.is_a?(Hash) && @samples.is_a?(Hash) && @load_reached.is_a?(Array) &&
               @fingerprints.keys.sort == @buckets.flatten.sort
          raise ArgumentError, "invalid shard plan observations or mutation fingerprints"
        end
      end

      def call(paths)
        shards = {}
        paths.each do |path|
          artifact = read_artifact(path)
          index, results = artifact.values_at("index", "results")
          raise ArgumentError, "duplicate shard result for #{index}" if shards.key?(index)

          ids = results.map { |record| record["full_id"] if record.is_a?(Hash) }
          unless ids.all?(String) && ids.sort == @buckets.fetch(index - 1).sort
            raise ArgumentError, "shard #{index} results do not match its assigned mutations"
          end
          unless results.all? { |record| valid_record?(record) }
            raise ArgumentError, "invalid shard result record in shard #{index}: #{path}"
          end

          shards[index] = results
        end
        missing = (1..@buckets.length).to_a - shards.keys
        raise ArgumentError, "missing shard results for #{missing.join(', ')}" unless missing.empty?

        shards.values.flatten(1).sort_by { |record| record.fetch("full_id") }
      end

      private

      def read_artifact(path)
        bytes = File.open(path, File::RDONLY | File::NONBLOCK) do |file|
          raise ArgumentError, "shard result must be a regular file: #{path}" unless file.stat.file?

          file.binmode.read(ShardPlan::MAX_BYTES + 1) || ""
        end
        raise ArgumentError, "shard result is too large: #{path}" if bytes.bytesize > ShardPlan::MAX_BYTES

        artifact = JSON.parse(bytes)
        unless artifact.is_a?(Hash) && artifact["version"].eql?(ShardPlan::VERSION) && artifact["results"].is_a?(Array)
          raise ArgumentError, "invalid shard result: #{path}"
        end
        raise ArgumentError, "shard result belongs to a different shard plan: #{path}" unless artifact["plan_digest"] == @digest

        index, total = artifact.values_at("index", "total")
        unless index.is_a?(Integer) && index.between?(1, @buckets.length) && total.eql?(@buckets.length)
          raise ArgumentError, "invalid shard result index or total: #{path}"
        end

        artifact
      rescue JSON::ParserError
        raise ArgumentError, "invalid shard result JSON: #{path}"
      rescue SystemCallError
        raise ArgumentError, "cannot read shard result: #{path}"
      end

      def valid_record?(record)
        return false unless Core::Classifier::STATUSES.include?(record["status"]) && valid_location?(record["location"])
        return false unless record.values_at("id", "site", "subject", "method_hash", "operator", "original", "mutated").all?(String)
        return false unless record.values_at("accepted", "invalid_reason", "error").all? { |value| value.nil? || value.is_a?(String) }
        return false unless @fingerprints.fetch(record["full_id"]) == ShardPlan.mutation_fingerprint(record)

        killer = record["killed_by"]
        (killer.nil? || @tests.key?(killer)) && valid_observations?(record) && valid_propagation?(record)
      end

      def valid_location?(location)
        return false unless location.is_a?(Hash) && @sources.key?(location["file"])

        line, column, end_line, end_column = location.values_at("line", "column", "end_line", "end_column")
        [line, column, end_line, end_column].all? { |value| value.is_a?(Integer) && value.positive? } &&
          (end_line > line || (end_line == line && end_column >= column))
      end

      def valid_observations?(record)
        site = record.fetch("site")
        tests = @reach.fetch(site, [])
        return false unless tests.is_a?(Array) && tests.all? { |id| @tests[id].is_a?(Hash) }

        coverage = tests.map { |id| @tests.fetch(id).merge("id" => id) }
        observed = record["observed"]
        record["covering_tests"] == coverage && record["load_reached"] == @load_reached.include?(site) &&
          observed == @samples.fetch(site, []) && observed.is_a?(Array) && observed.all? { |pair| pair.is_a?(Array) && pair.length == 2 }
      end

      def valid_propagation?(record)
        return !record.key?("propagation") unless record["status"] == "not_revealed"

        proof = record["propagation"]
        return false unless proof.is_a?(Hash) && @tests.key?(proof["test_id"]) && proof["call"].is_a?(Integer) && proof["call"].positive?

        proof.values_at("original", "mutant").all? { |exit| exit.is_a?(Array) && exit.first.is_a?(String) }
      end
    end
  end
end
