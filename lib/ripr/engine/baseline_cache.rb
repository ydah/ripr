# frozen_string_literal: true

module Ripr
  module Engine
    class BaselineCache
      attr_reader :test_ids, :reused_count

      def initialize(previous, env_hash:, source_hash:, test_hashes:, tests:, full: false)
        @previous = previous
        @env_hash = env_hash
        @source_hash = source_hash
        @test_hashes = test_hashes
        @tests = tests.to_h { |test| [test.fetch("id"), test] }
        @retained = {}
        @test_ids = nil
        prepare unless full
        @reused_count = @retained.length
      end

      def combine(fresh, load_reached: [])
        fresh ||= { "tests" => {}, "probe" => empty_probe }
        old_probe = @retained.empty? ? empty_probe : @previous.fetch("probe")
        retained_ids = @retained.keys
        dirty_ids = @retained.empty? ? [] : @previous.fetch("tests").keys - retained_ids
        samples = old_probe.fetch("samples").reject do |site, _pairs|
          old_probe.fetch("reach").fetch(site, []).intersect?(dirty_ids)
        end
        probe = {
          "reach" => merge_members(old_probe.fetch("reach"), fresh.fetch("probe").fetch("reach"), retained_ids),
          "infect" => merge_members(old_probe.fetch("infect"), fresh.fetch("probe").fetch("infect"), retained_ids),
          "samples" => samples.merge(fresh.fetch("probe").fetch("samples")) { |_site, old, current| (old + current).uniq.take(3) },
          "load_reached" => (old_probe.fetch("load_reached") + fresh.fetch("probe").fetch("load_reached") + load_reached).uniq
        }
        { "success" => true, "failures" => [], "tests" => @retained.merge(fresh.fetch("tests")), "probe" => probe,
          "env_hash" => @env_hash, "source_hash" => @source_hash, "test_hashes" => @test_hashes }
      end

      private

      def prepare
        return unless valid?(@previous)

        old_hashes = @previous.fetch("test_hashes")
        changed = old_hashes != @test_hashes
        return if changed && (@previous.fetch("probe").fetch("load_reached").any? || @tests.values.any? do |test|
          !@test_hashes.key?(test.fetch("file"))
        end)

        @retained = @previous.fetch("tests").select do |id, metadata|
          current = @tests[id]
          current && current["file"] == metadata["file"] && current["line"] == metadata["line"] &&
            old_hashes[current["file"]] == @test_hashes[current["file"]]
        end
        @test_ids = @tests.keys - @retained.keys
      end

      def valid?(data)
        return false unless data.is_a?(Hash) && data["success"] == true && data["env_hash"] == @env_hash &&
                            data["source_hash"] == @source_hash && data["tests"].is_a?(Hash) && data["test_hashes"].is_a?(Hash)
        return false unless data["tests"].all? do |id, test|
          id.is_a?(String) && !id.empty? && test.is_a?(Hash) && test["file"].is_a?(String) && !test["file"].empty? &&
          test["line"].is_a?(Integer) && test["line"].positive? && test["duration_ms"].is_a?(Numeric) &&
          test["duration_ms"].finite? && test["duration_ms"] >= 0
        end

        probe = data["probe"]
        return false unless probe.is_a?(Hash) && probe["load_reached"].is_a?(Array) && probe["load_reached"].all?(String)
        return false unless %w[reach infect].all? do |key|
          probe[key].is_a?(Hash) && probe[key].all? do |site, ids|
            site.is_a?(String) && ids.is_a?(Array) && ids.all? { |id| id.is_a?(String) && data["tests"].key?(id) }
          end
        end

        probe["samples"].is_a?(Hash) && probe["samples"].all? { |site, pairs| site.is_a?(String) && samples?(pairs) }
      end

      def samples?(samples)
        samples.is_a?(Array) && samples.length <= 3 && samples.all? do |pair|
          pair.is_a?(Array) && pair.length == 2 && pair.all? do |value|
            value.nil? || [true, false].include?(value) || value.is_a?(String) || (value.is_a?(Numeric) && value.finite?)
          end
        end
      end

      def merge_members(previous, current, retained_ids)
        pruned = previous.transform_values { |ids| ids & retained_ids }.reject { |_site, ids| ids.empty? }
        pruned.merge(current) { |_site, old, fresh| (old + fresh).uniq }
      end

      def empty_probe
        { "reach" => {}, "infect" => {}, "samples" => {}, "load_reached" => [] }
      end
    end
  end
end
