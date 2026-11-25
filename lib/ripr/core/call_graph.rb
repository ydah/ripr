# frozen_string_literal: true

require "digest"
require "prism"

module Ripr
  module Core
    class CallGraph
      PROCESS_CALLS = %i[exec fork spawn system ` set_trace_func].freeze
      REFLECTIVE_CALLS = %i[eval class_eval module_eval instance_eval define_method define_singleton_method].freeze
      SAFE_IO_CALLS = %i[== === equal? class is_a? kind_of? nil? respond_to? tty? isatty absolute_path absolute_path? basename dirname
                         expand_path extname fnmatch fnmatch? join path realpath realdirpath split exist? exists?
                         file? directory? symlink?].freeze
      REFLECTIVE_OWNERS = [Kernel, Kernel.singleton_class, BasicObject, Module, Binding].freeze
      INSTRUCTION_READS = %i[disasm disassemble to_binary to_a].freeze
      STRUCTURAL_NODES = %i[def_node class_node module_node singleton_class_node pre_execution_node post_execution_node].freeze
      DEFERRED_NODES = %i[block_node lambda_node].freeze

      attr_reader :structure_hash

      def initialize(sources)
        @files = {}
        @hashes = {}
        @lines = {}
        @deferred_methods = []
        layouts = sources.sort.map { |path, source| inventory(path, source) }
        @structure_hash = Digest::SHA256.hexdigest(Marshal.dump(layouts)) unless layouts.include?(nil)
      end

      def signature(dependencies)
        return unless structure_hash && dependencies.is_a?(Array) &&
                      dependencies.all? { |key| key.is_a?(String) && @hashes.key?(key) }

        @hashes.slice(*dependencies)
      end

      def method_hashes
        @hashes.dup.freeze
      end

      def deferred_methods
        @deferred_methods.dup.freeze
      end

      def source_path(path)
        @files[path]
      end

      def methods_at(path, line, name)
        @lines.fetch(path).fetch(line, []).select { |key| key.end_with?(":#{name}") }
      end

      def trace(&)
        return [yield, nil] unless structure_hash

        rspec_options = $LOADED_FEATURES.find { |path| path.end_with?("/rspec/core/configuration_options.rb") }
        erb = ERB.instance_method(:result).source_location&.first if defined?(ERB)
        frameworks = %w[minitest rspec-core rspec-mocks rspec-support rspec-expectations].filter_map { |name| gem_prefix(name) }
        frameworks << "#{File.dirname(rspec_options, 4)}/" if rspec_options
        dependencies = {}
        uncertain = false
        tracer = TracePoint.new(:call, :c_call, :b_call) do |event|
          next if uncertain

          if opaque_call?(event, rspec_options, erb, frameworks)
            uncertain = true
          elsif event.event != :c_call && (path = @files[event.path])
            @lines[path].fetch(event.lineno, []).each { |key| dependencies[key] = true }
          end
        end
        result = tracer.enable(&)
        [result, uncertain ? nil : dependencies.keys.sort]
      end

      private

      def inventory(path, source)
        parsed = Prism.parse(source, filepath: path)
        return if parsed.failure?

        path = path.dup.freeze
        @files[path] = @files[File.expand_path(path)] = path
        @files[File.realpath(path)] = path if File.file?(path)
        @lines[path] = {}
        sections = [path]
        cursor = 0
        editable_methods(parsed.value).sort_by { |node, _| node.location.start_offset }.each do |node, kind|
          location = node.body.location
          definition = node.location
          sections << source.byteslice(cursor...location.start_offset)
          sections << [definition.start_line, definition.start_column, location.start_line, location.end_line]
          cursor = location.end_offset
          key = "#{path.bytesize}:#{path}:#{definition.start_line}:#{definition.start_column}:#{node.name}".freeze
          @hashes[key] = Digest::SHA256.hexdigest(location.slice).freeze
          @deferred_methods << key if kind == :deferred
          (definition.start_line..definition.end_line).each { |line| (@lines[path][line] ||= []) << key }
        end
        sections << source.byteslice(cursor..)
      end

      def editable_methods(root)
        methods = []
        pending = [root]
        until pending.empty?
          node = pending.pop
          if node.is_a?(Prism::DefNode)
            kind = method_body_kind(node)
            methods << [node, kind] if kind
          else
            pending.concat(node.compact_child_nodes)
          end
        end
        methods
      end

      def method_body_kind(definition)
        body = definition.body
        return unless body && (definition.receiver.nil? || definition.receiver.is_a?(Prism::SelfNode))

        location = body.location
        kind = :inline
        pending = [body]
        until pending.empty?
          node = pending.pop
          return if STRUCTURAL_NODES.include?(node.type) || node.location.start_offset < location.start_offset ||
                    node.location.end_offset > location.end_offset ||
                    (node.respond_to?(:opening_loc) && node.opening_loc&.slice&.start_with?("<<"))

          kind = :deferred if DEFERRED_NODES.include?(node.type)
          pending.concat(node.compact_child_nodes)
        end
        kind
      end

      def gem_prefix(name)
        specification = Gem.loaded_specs[name] if defined?(Gem)
        "#{specification.full_gem_path}/" if specification
      end

      def opaque_call?(event, rspec_options, erb, frameworks)
        name = event.method_id
        return true if PROCESS_CALLS.include?(name)

        owner = event.defined_class
        return true if owner == TracePoint && %i[enable disable].include?(name)

        if REFLECTIVE_CALLS.include?(name) && REFLECTIVE_OWNERS.include?(owner)
          return false if event.path && frameworks.any? { |path| event.path.start_with?(path) }
          return false if name == :eval && erb && event.path == erb &&
                          caller_locations.any? { |location| location.absolute_path == rspec_options }

          return true
        end
        return true if owner == RubyVM::InstructionSequence && INSTRUCTION_READS.include?(name)
        return true if owner == RubyVM::InstructionSequence.singleton_class && name == :of
        return true if owner == RubyVM::AbstractSyntaxTree.singleton_class && %i[of parse_file].include?(name)
        return true if owner == Prism.singleton_class && name.to_s.end_with?("_file")

        # Ruby 3.3 reports line 0 for the native loader's encoding changes before entering the source file.
        if name == :set_encoding && owner == IO && event.event == :c_call && event.lineno.zero?
          frame = caller_locations(2, 1).first
          return false if %w[require require_relative load].include?(frame&.base_label) && frame.path != event.path &&
                          event.self.instance_of?(File) && event.self.path == event.path
        end

        return false if SAFE_IO_CALLS.include?(name)
        return false if name == :read && rspec_options && event.path == rspec_options

        case event.self
        when IO, File::Stat then true
        else [File, IO, File::Stat, FileTest].include?(event.self)
        end
      end
    end
  end
end
