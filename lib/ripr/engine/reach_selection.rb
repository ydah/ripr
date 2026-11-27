# frozen_string_literal: true

require_relative "reach_map"

module Ripr
  module Engine
    class ReachSelection
      class Unusable < Ripr::Error; end

      MAX_ARTIFACT_BYTES = 32 * 1024 * 1024
      FilePlan = Data.define(:tests, :ids, :superclasses)
      private_constant :FilePlan

      def initialize(config, sources, mutants)
        if !config[:since] || config[:full] || config[:static] || config[:boot] || config[:include_tests_diff] || !config[:only].empty?
          raise Unusable, "run options require the full baseline"
        end

        path = config[:reach_map]
        raise Unusable, "artifact is missing or too large" unless File.file?(path) && File.size(path) <= MAX_ARTIFACT_BYTES

        @artifact = JSON.parse(File.binread(path, MAX_ARTIFACT_BYTES))
        unless @artifact.is_a?(Hash) && [3, ReachMap::VERSION].include?(@artifact["version"])
          raise Unusable, "artifact version is unsupported"
        end
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

      def load_files(paths, framework, allowed:)
        return paths unless @artifact["version"] == ReachMap::VERSION
        return paths unless @artifact.values_at("test_load_order", "framework") == [paths, framework]

        tests = @artifact.fetch("tests")
        ids = select_ids(tests, paths, framework)
        required = ids.map { |id| tests.fetch(id).fetch("file") }.uniq
        return paths unless (required - paths).empty?

        required |= paths - allowed
        retained = paths.take(paths.rindex { |path| required.include?(path) } + 1)
        return paths if retained == paths

        superclasses = declaration_superclasses(retained, paths.drop(retained.size), tests, framework)
        return paths unless superclasses

        @file_plan = FilePlan.new(tests.select { |_, test| retained.include?(test.fetch("file")) }, ids, superclasses)
        retained
      rescue Ripr::Error, SystemCallError, IOError, ArgumentError
        paths
      end

      def test_ids(discovered, framework:, paths:, rails:, load_reached:)
        if !load_reached.empty? || framework != @artifact["framework"] || !@capture.stable_inputs? ||
           !@capture.matching_load?(@artifact["load_reads"])
          raise Unusable, "test discovery or load-time reach changed"
        end

        database = @capture.database_inputs(rails)
        raise Unusable, "Rails database inputs changed or are unknown" unless database && database == @artifact["database_inputs"]

        tests = discovered.to_h { |test| [test.fetch("id"), @capture.test_metadata(test)] }
        raise Unusable, "discovered tests changed" unless tests == (@file_plan&.tests || @artifact.fetch("tests"))

        if @file_plan && !safe_registration?(framework, @file_plan.superclasses)
          raise Unusable, "test file pruning cannot verify #{framework} registration hooks"
        end

        @file_plan ? @file_plan.ids : select_ids(tests, paths, framework)
      rescue Unusable
        raise
      rescue Ripr::Error, SystemCallError, IOError, ArgumentError => e
        raise Unusable, "cannot validate the reach map (#{e.class})"
      end

      private

      def select_ids(tests, paths, framework)
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
      end

      def declaration_superclasses(retained, omitted, tests, framework)
        retained_nodes = retained.map { |path| statements(path) }
        imports = retained_nodes.flat_map { |nodes| nodes.take_while { |node| literal_require(node) }.map { |node| literal_require(node) } }
        omitted_classes = []
        superclasses = []
        omitted.each do |path|
          nodes = statements(path)
          requires = nodes.take_while { |node| literal_require(node) }
          declarations = nodes.drop(requires.size)
          return nil if declarations.empty? || requires.any? { |node| !imports.include?(literal_require(node)) }

          if framework == "minitest"
            return nil unless minitest_declarations?(path, declarations, tests)

            omitted_classes.concat(declarations.map(&:name))
            superclasses.concat(declarations.map { |node| node.superclass.location.slice })
          else
            return nil unless declarations.all? { |node| literal_rspec_group?(node, receiver: "RSpec") }
          end
        end
        return if registration_dependency?(retained_nodes.flatten, framework, omitted_classes)

        superclasses.uniq
      end

      def safe_registration?(framework, superclasses)
        if framework == "rspec"
          config = ::RSpec.configuration
          return false unless config.respond_to?(:on_example_group_definition_callbacks)

          callbacks = config.on_example_group_definition_callbacks
          return false unless callbacks.is_a?(Array) && callbacks.empty?

          repository = config.instance_variable_get(:@derived_metadata_blocks)
          return false unless repository.respond_to?(:items_and_filters)

          filters = repository.items_and_filters
          return filters.is_a?(Array) && filters.empty?
        end

        paths = %w[minitest activesupport].flat_map { |name| Gem.loaded_specs[name]&.full_require_paths || [] }
        roots = paths.filter_map { |path| "#{File.realpath(path)}/" if File.directory?(path) }
        return false unless standard_hook?(Object, :const_added, Module, [])

        superclasses.all? do |superclass|
          namespace, name = superclass.split("::")
          namespace = loaded_constant(Object, namespace)
          next false unless namespace.is_a?(Module)

          base = loaded_constant(namespace, name)
          next false unless base.is_a?(Class)

          standard_hook?(base, :inherited, Class, roots) && standard_hook?(base, :method_added, Module, roots)
        end
      rescue NameError, TypeError, SystemCallError
        false
      end

      def standard_hook?(receiver, name, native_owner, roots)
        hook = receiver.method(name)
        while (source = hook.source_location&.first)
          return false unless File.realpath(source).start_with?(*roots)

          hook = hook.super_method
          return false unless hook
        end
        hook.owner == native_owner && hook.original_name == name && hook.super_method.nil?
      end

      def loaded_constant(namespace, name)
        return if namespace.autoload?(name, false) || !namespace.const_defined?(name, false)

        namespace.const_get(name, false)
      end

      def registration_dependency?(nodes, framework, omitted_classes)
        until nodes.empty?
          node = nodes.pop
          if framework == "minitest"
            return true if omitted_class_reference?(node, omitted_classes)
          elsif rspec_registry_reference?(node)
            return true
          end
          nodes.concat(node.compact_child_nodes)
        end
        false
      end

      def omitted_class_reference?(node, classes)
        return classes.include?(node.name) if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
        return false unless node.is_a?(Prism::CallNode) && %i[const_get const_defined? const_source_location].include?(node.name)

        name = node.arguments&.arguments&.first
        (name.is_a?(Prism::StringNode) || name.is_a?(Prism::SymbolNode)) && classes.include?(name.unescaped.delete_prefix("::").to_sym)
      end

      def rspec_registry_reference?(node)
        if node.is_a?(Prism::ConstantPathNode)
          return %w[RSpec::Core::World RSpec::Core::Configuration RSpec::Core::ExampleGroup].include?(node.location.slice.delete_prefix("::"))
        end

        node.is_a?(Prism::CallNode) && %w[RSpec ::RSpec].include?(node.receiver&.location&.slice) &&
          %i[world configuration configure reset clear_examples].include?(node.name)
      end

      def statements(path)
        result = Prism.parse_file(path)
        raise Unusable, "cannot inspect test declarations" unless result.success?

        result.value.statements&.body || []
      end

      def literal_require(node)
        return unless node.is_a?(Prism::CallNode) && !node.receiver && !node.block && node.name == :require

        args = node.arguments&.arguments
        args.first.unescaped if args&.size == 1 && args.first.is_a?(Prism::StringNode)
      end

      def minitest_declarations?(path, declarations, tests)
        declarations.all? do |node|
          next false unless node.is_a?(Prism::ClassNode) && node.constant_path.is_a?(Prism::ConstantReadNode) &&
                            %w[Minitest::Test ActiveSupport::TestCase].include?(node.superclass&.location&.slice) &&
                            node.body.is_a?(Prism::StatementsNode)

          prefix = "#{node.name}#"
          class_tests = tests.select { |id, _| id.start_with?(prefix) }
          class_tests.any? && class_tests.values.all? { |test| test.fetch("file") == path } &&
            node.body.body.all? { |declaration| minitest_method?(declaration) }
        end
      end

      def minitest_method?(node)
        return !node.receiver if node.is_a?(Prism::DefNode)
        return false unless node.is_a?(Prism::CallNode) && !node.receiver && node.block.is_a?(Prism::BlockNode)

        (node.name == :test && literal_description?(node)) || (%i[setup teardown].include?(node.name) && !node.arguments)
      end

      def literal_rspec_group?(node, receiver: nil)
        return false unless node.is_a?(Prism::CallNode) && node.receiver&.location&.slice == receiver &&
                            %i[describe context].include?(node.name) && literal_description?(node) &&
                            node.block.is_a?(Prism::BlockNode) && !node.block.parameters && node.block.body.is_a?(Prism::StatementsNode)

        node.block.body.body.all? do |child|
          literal_rspec_group?(child) ||
            (child.is_a?(Prism::CallNode) && !child.receiver && %i[it example specify].include?(child.name) &&
             literal_description?(child) && child.block.is_a?(Prism::BlockNode))
        end
      end

      def literal_description?(node)
        args = node.arguments&.arguments
        args&.size == 1 && args.first.is_a?(Prism::StringNode)
      end

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
        valid_tests = tests.is_a?(Hash) && tests.values.all? do |test|
          test.is_a?(Hash) && test["file"].is_a?(String) && test["line"].is_a?(Integer)
        end
        unless valid_tests &&
               id_list?(order, tests.keys) && order.size == tests.size && reach.is_a?(Hash) &&
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
