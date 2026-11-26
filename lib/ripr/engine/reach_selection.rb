# frozen_string_literal: true

require_relative "reach_map"

module Ripr
  module Engine
    class ReachSelection
      class Unusable < Ripr::Error; end

      MAX_ARTIFACT_BYTES = 32 * 1024 * 1024

      def initialize(config, sources, mutants)
        if !config[:since] || config[:full] || config[:static] || config[:boot] || config[:include_tests_diff] || !config[:only].empty?
          raise Unusable, "run options require the full baseline"
        end

        path = config[:reach_map]
        raise Unusable, "artifact is missing or too large" unless File.file?(path) && File.size(path) <= MAX_ARTIFACT_BYTES

        @artifact = JSON.parse(File.binread(path, MAX_ARTIFACT_BYTES))
        raise Unusable, "artifact version is unsupported" unless @artifact.is_a?(Hash) && @artifact["version"] == ReachMap::VERSION
        raise Unusable, "boot or test loading made an opaque observation" unless @artifact["opaque_load"] == false

        @git = Git.new
        @base = @git.merge_base(config[:since])
        @prefix = @git.project_prefix
        raise Unusable, "artifact base or project does not match" unless @artifact.values_at("base", "project_prefix") == [@base, @prefix]

        @capture = ReachMap.new(sources, config)
        current = @capture.provenance
        comparable = current.except("sources", "method_hashes")
        raise Unusable, "project structure or boot inputs changed" unless @artifact.slice(*comparable.keys) == comparable

        validate_sources(current)
        validate_observations(current)
        @required_methods = @changed_methods | mutants.flat_map do |mutant|
          ids = @capture.method_ids(mutant)
          raise Unusable, "a mutant is outside a known method body" if ids.empty?

          ids
        end
        if @required_methods.intersect?(@artifact.fetch("unattributed") | current.fetch("deferred_methods"))
          raise Unusable, "a relevant method has unattributed reach or deferred execution"
        end
      rescue Unusable
        raise
      rescue JSON::ParserError, Ripr::Error, SystemCallError, IOError, ArgumentError => e
        raise Unusable, "cannot validate the reach map (#{e.class})"
      end

      def capture(&)
        @capture.capture(methods: false, &)
      end

      def test_ids(discovered, framework:, paths:, rails:, load_reached:)
        if !load_reached.empty? || framework != @artifact["framework"] || !@capture.stable_inputs? ||
           !@capture.matching_load?(@artifact["load_reads"])
          raise Unusable, "test discovery or load-time reach changed"
        end

        database = @capture.database_inputs(rails)
        raise Unusable, "Rails database inputs changed or are unknown" unless database && database == @artifact["database_inputs"]

        tests = discovered.to_h { |test| [test.fetch("id"), @capture.test_metadata(test)] }
        raise Unusable, "discovered tests changed" unless tests == @artifact.fetch("tests")

        files = @capture.test_inputs(paths + tests.values.map { |test| test.fetch("file") })
        changed_tests = validate_tests(files, tests, framework)
        changed_paths = @changed_source_paths | changed_tests
        unknown_paths = @git.repository_changes(@base) - changed_paths.map { |path| "#{@prefix}#{path}" }
        raise Unusable, "repository paths outside the reach map changed" unless unknown_paths.empty?

        affected = @required_methods.flat_map { |id| @artifact.fetch("reach").fetch(id, []) } | @artifact.fetch("opaque_tests")
        affected |= tests.filter_map { |id, test| id if changed_tests.include?(test.fetch("file")) }
        selected = @artifact.fetch("test_order") & affected
        raise Unusable, "the map cannot narrow this baseline" if selected.empty? || selected.size == tests.size

        selected
      rescue Unusable
        raise
      rescue Ripr::Error, SystemCallError, IOError, ArgumentError => e
        raise Unusable, "cannot validate the reach map (#{e.class})"
      end

      private

      def valid_digests?(entries)
        entries.is_a?(Hash) && entries.values.all? { |digest| digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/) }
      end

      def validate_sources(current)
        old_sources, old_methods = @artifact.values_at("sources", "method_hashes")
        new_sources, new_methods = current.values_at("sources", "method_hashes")
        unless valid_digests?(old_sources) && valid_digests?(old_methods) && old_sources.keys.sort == new_sources.keys.sort &&
               old_methods.keys.sort == new_methods.keys.sort
          raise Unusable, "source or method inventory changed"
        end

        @changed_source_paths = new_sources.keys.reject { |path| old_sources[path] == new_sources[path] }
        unless @changed_source_paths.all? { |path| Digest::SHA256.hexdigest(@git.content(@base, path)) == old_sources[path] }
          raise Unusable, "recorded source content does not match the base"
        end

        @changed_methods = new_methods.keys.reject { |key| old_methods[key] == new_methods[key] }
        if @changed_source_paths.empty? || @changed_methods.empty? || !id_list?(@artifact["unresolved_files"], new_sources.keys) ||
           @changed_source_paths.intersect?(@artifact["unresolved_files"])
          raise Unusable, "source changes have unresolved method reach"
        end
      end

      def validate_observations(current)
        tests, order, reach, unattributed, opaque = @artifact.values_at("tests", "test_order", "reach", "unattributed", "opaque_tests")
        methods = current.fetch("method_hashes").keys
        unless tests.is_a?(Hash) && id_list?(order, tests.keys) && order.size == tests.size && reach.is_a?(Hash) &&
               (reach.keys - methods).empty? && reach.values.all? { |ids| id_list?(ids, tests.keys) } &&
               id_list?(unattributed, methods) && id_list?(opaque, tests.keys)
          raise Unusable, "artifact has invalid reach or test IDs"
        end
      end

      def id_list?(ids, inventory)
        ids.is_a?(Array) && ids == ids.uniq && (ids - inventory).empty?
      end

      def validate_tests(current, tests, framework)
        old = @artifact["test_files"]
        raise Unusable, "test file inventory changed" unless valid_digests?(old) && old.keys.sort == current.keys.sort

        changed = current.keys.reject { |path| old[path] == current[path] }
        locations = tests.values.group_by { |test| test.fetch("file") }
        changed.each do |path|
          base_source = @git.content(@base, path)
          before = test_layout(base_source, locations.fetch(path, []), framework)
          after = test_layout(File.binread(path), locations.fetch(path, []), framework)
          if Digest::SHA256.hexdigest(base_source) != old[path] || !before || before != after
            raise Unusable, "test support or registration changed"
          end
        end
        changed
      end

      def test_layout(source, tests, framework)
        return if tests.empty?

        parsed = Prism.parse(source)
        return if parsed.failure?

        lines = tests.map { |test| test.fetch("line") }
        pending = [parsed.value]
        bodies = []
        until pending.empty?
          node = pending.pop
          body = lines.include?(node.location.start_line) && test_body(node, framework)
          if body
            bodies << body.location
          else
            pending.concat(node.compact_child_nodes)
          end
        end
        return unless bodies.size == tests.size

        cursor = 0
        layout = bodies.sort_by(&:start_offset).map do |body|
          unchanged = source.byteslice(cursor...body.start_offset)
          cursor = body.end_offset
          unchanged
        end
        layout << source.byteslice(cursor..)
      end

      def test_body(node, framework)
        if framework == "minitest"
          node.body if node.is_a?(Prism::DefNode) && node.receiver.nil? && node.name.start_with?("test_")
        elsif node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[it specify example].include?(node.name) && node.block.is_a?(Prism::BlockNode)
          node.block.body
        end
      end
    end
  end
end
