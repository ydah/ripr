# frozen_string_literal: true

require "tempfile"
require "fileutils"
require "json"
require_relative "../core/call_graph"
require_relative "../version"

module Ripr
  module Engine
    class ReachMap
      VERSION = 4
      PATH = ".ripr/reach-map.json"
      TEST_INPUTS = %w[test/**/* spec/**/* .rspec .rspec-local].freeze
      BOOT_INPUTS = %w[config/**/* db/**/* Gemfile Gemfile.lock gems.rb gems.locked .env* .ripr.yml].freeze
      SETTINGS = %i[include exclude framework tests operators arid_callees seed samples boot rails static].freeze
      PROCESS_CALLS = %i[exec fork spawn system ` popen].freeze
      PROCESS_OWNERS = [Kernel, Kernel.singleton_class, Process.singleton_class, IO.singleton_class].freeze
      FILE_METHODS = %i[read binread readlines readline gets getc getbyte readchar readbyte readpartial read_nonblock sysread pread
                        open new foreach each each_line each_byte each_char stat lstat atime mtime ctime birthtime size size? exist? exists?
                        file? directory? symlink? readable? writable? executable? empty? readlink glob [] entries children each_child
                        write binwrite syswrite pwrite copy_stream].freeze
      FILE_CALLS = FILE_METHODS.to_h { |name| [name, true] }.freeze
      FILE_OWNERS = [File, IO, File::Stat, FileTest, Dir].each_with_object({}) do |owner, owners|
        owners[owner] = owners[owner.singleton_class] = true
      end.freeze
      FILE_PATH = File.instance_method(:path)
      INSTANCE_OF = Object.instance_method(:instance_of?)
      NON_SCALAR_FILE_METHODS = %i[open new write binwrite syswrite pwrite copy_stream foreach
                                   each each_line each_byte each_char each_child].freeze
      FILE_READS = (FILE_METHODS - NON_SCALAR_FILE_METHODS).to_h { |name| [name, true] }.freeze
      REFLECTIVE_CALLS = %i[eval class_eval module_eval instance_eval define_method define_singleton_method load
                            const_source_location].freeze
      REFLECTIVE_OWNERS = [Kernel, Kernel.singleton_class, Module, BasicObject, Binding].freeze
      INSPECTIONS = {
        RubyVM::InstructionSequence => %i[disasm disassemble to_binary to_a],
        RubyVM::InstructionSequence.singleton_class => RubyVM::InstructionSequence.singleton_methods.grep(/\A(?:of|compile_file.*)\z/),
        RubyVM::AbstractSyntaxTree.singleton_class => %i[of parse_file],
        Prism.singleton_class => Prism.singleton_methods.grep(/_file\z/)
      }.freeze
      EFFECT_NAMES = (FILE_METHODS + REFLECTIVE_CALLS + PROCESS_CALLS + INSPECTIONS.values.flatten +
                       %i[enable disable set_trace_func add_trace_func]).to_h { |name| [name, true] }.freeze
      LOADER_PATH = File.expand_path("../loader.rb", __dir__)
      MAX_LOAD_INPUTS = 10_000
      MAX_LOAD_STRING_BYTES = 2 * 1024 * 1024
      MAX_LOAD_BYTES = 16 * 1024 * 1024

      def initialize(sources, config)
        @root = Dir.pwd
        @graph = Core::CallGraph.new(sources)
        raise ArgumentError, "reach-map requires parseable project Ruby files" if sources.empty? || !@graph.structure_hash

        @sources = sources.to_h { |path, source| [relative_input(path), digest(source)] }
        @boot = config[:boot]
        @test_patterns = TEST_INPUTS + Array(config[:tests])
        @test_inputs = glob_fingerprints(@test_patterns)
        @boot_inputs = boot_fingerprints
        @external_inputs = external_fingerprints
        @runtime = { "ruby" => RUBY_DESCRIPTION, "platform" => RUBY_PLATFORM, "prism" => Prism::VERSION,
                     "ripr" => Ripr::VERSION, "environment_hash" => digest(Marshal.dump(ENV.to_a.sort)),
                     "loader" => ENV.fetch("RIPR_LOADER", nil) == "require" ? "require" : "load_iseq" }
        @settings = config.to_h.slice(*SETTINGS).transform_keys(&:to_s)
        @settings["boot"] = relative_input(@boot) if @boot
        @reach = Hash.new { |hash, id| hash[id] = {} }
        @unattributed = {}
        @opaque_tests = {}
        @opaque_load = false
        @load_reads = Digest::SHA256.new
        @load_read_count = 0
        @load_bytes = 0
        @unresolved_files = $LOADED_FEATURES.filter_map { |path| @graph.source_path(path) }.to_h { |path| [path, true] }
      end

      def capture(loading: true, methods: true, &)
        directory_returns = start_directory_return_trace(loading) unless methods
        events = directory_returns ? %i[c_call c_return] : %i[return c_call c_return]
        events.unshift(:call) if methods
        trace = TracePoint.new(*events) do |event|
          observe_effect(event, loading)
          record(event) if methods && event.event == :call
        end
        trace.enable(&)
      ensure
        directory_returns&.disable
      end

      def observations
        { "reach" => @reach.sort.to_h.transform_values { |ids| ids.keys.sort }, "unattributed" => @unattributed.keys.sort,
          "unresolved_files" => @unresolved_files.keys.sort, "opaque_tests" => @opaque_tests.keys.sort,
          "opaque_load" => @opaque_load, "load_reads" => @load_reads.hexdigest }
      end

      def matching_load?(digest)
        !@opaque_load && digest == @load_reads.hexdigest
      end

      def provenance
        { "runtime" => @runtime, "settings" => @settings, "structure_hash" => @graph.structure_hash,
          "method_hashes" => @graph.method_hashes, "sources" => @sources, "deferred_methods" => @graph.deferred_methods,
          "boot_inputs" => @boot_inputs, "external_inputs" => @external_inputs }
      end

      def method_ids(mutant)
        name = mutant.subject.split(/[.#]/, 2).last.sub(/\[\d+\]\z/, "")
        @graph.methods_at(mutant.location.file, mutant.method_start, name)
      end

      def test_inputs(paths)
        @test_inputs.merge(fingerprints(paths)).sort.to_h
      end

      def test_metadata(test)
        { "file" => relative_input(test.fetch("file")), "line" => test.fetch("line") }
      end

      def database_inputs(rails)
        rails ? rails.cache_snapshot_paths&.map { |path| Digest::SHA256.file(path).hexdigest } : []
      rescue SystemCallError, IOError
        nil
      end

      def stable_inputs?
        Dir.pwd == @root && @sources == fingerprints(@sources.keys) && glob_fingerprints(@test_patterns) == @test_inputs &&
          boot_fingerprints == @boot_inputs && external_fingerprints == @external_inputs
      end

      def write(result, discovered, test_files, framework, base, git, database_inputs:)
        raise ArgumentError, "working directory changed during reach-map capture" unless Dir.pwd == @root

        tests = result.fetch("tests").transform_values { |test| test_metadata(test) }
        expected = discovered.to_h { |test| [test.fetch("id"), test_metadata(test)] }
        unless !tests.empty? && tests == expected && complete_attribution?(result.fetch("observations"), tests)
          raise BaselineFailure, "reach-map requires a complete baseline"
        end

        raise ArgumentError, "Git HEAD changed during reach-map capture" unless git.clean_head == base

        raise ArgumentError, "project inputs changed during reach-map capture" unless stable_inputs?

        inputs = test_inputs(test_files + tests.values.map { |test| test.fetch("file") })
        manifest = provenance.merge("version" => VERSION, "base" => base, "project_prefix" => git.project_prefix,
                                    "framework" => framework, "database_inputs" => database_inputs, "tests" => tests,
                                    "test_order" => tests.keys, "test_files" => inputs, "test_load_order" => test_files)
        atomic_write(manifest.merge(result.fetch("observations")))
        PATH
      end

      private

      def record(event)
        path = @graph.source_path(event.path)
        return unless path

        ids = @graph.methods_at(path, event.lineno, event.method_id)
        if ids.empty?
          @unresolved_files[path] = true
        elsif (test = R.current_test)
          ids.each { |id| @reach[id][test] = true }
        else
          ids.each { |id| @unattributed[id] = true }
        end
      end

      def complete_attribution?(observations, tests)
        observations.fetch("reach").values.all? { |ids| ids.all? { |id| tests.key?(id) } } &&
          observations.fetch("opaque_tests").all? { |id| tests.key?(id) }
      end

      def record_opaque
        test = R.current_test
        if test
          @opaque_tests[test] = true
        else
          @opaque_load = true
        end
      end

      def start_directory_return_trace(loading)
        query = Dir.method(:[])
        return unless query.source_location&.first == "<internal:dir>"

        owner_thread = Thread.current
        trace = TracePoint.new(:return) do |event|
          observe_effect(event, loading) if Thread.current.equal?(owner_thread)
        end
        trace.enable(target: query)
        trace
      rescue ArgumentError, NameError
        trace&.disable
        nil
      end

      def observe_effect(event, loading)
        name = event.method_id
        return unless EFFECT_NAMES[name]

        if FILE_CALLS[name] && file_owner?(event.defined_class)
          return if event.path == LOADER_PATH || !project_invocation?(event.path)

          if %i[call return].include?(event.event) && builtin_directory_query?(event)
            if event.event == :return
              loading ? record_load_read(event) : record_opaque
            end
          elsif event.event != :return
            observe_file(event, loading)
          end
        elsif %i[call c_call].include?(event.event) && opaque_call?(event)
          record_opaque
        end
      end

      def builtin_directory_query?(event)
        event.defined_class == Dir.singleton_class && event.method_id == :[] && event.path == "<internal:dir>"
      end

      def observe_file(event, loading)
        name = event.method_id
        returning = event.event == :c_return
        if loading && FILE_READS[name] && event.event != :call
          record_load_read(event) if returning
        elsif name == :open && event.event != :call
          record_opaque if returning && !unchanged_fixture?(event.return_value)
        elsif !returning && !unchanged_fixture?(event.self)
          record_opaque
        end
      end

      def record_load_read(event)
        value = event.return_value
        @load_read_count += 1
        if @load_read_count > MAX_LOAD_INPUTS || !scalar_file_value?(value) || (event.method_id == :glob && !value.is_a?(Array))
          @opaque_load = true
          return
        end

        input = Marshal.dump([event.path.delete_prefix("#{@root}/"), event.method_id, value])
        @load_bytes += input.bytesize
        if @load_bytes > MAX_LOAD_BYTES
          @opaque_load = true
        else
          @load_reads << input
        end
      end

      def scalar_file_value?(value)
        case value
        when NilClass, TrueClass, FalseClass, Integer then true
        when String then value.bytesize <= MAX_LOAD_STRING_BYTES
        when Array then value.size <= 1_024 && value.all? { |entry| entry.is_a?(String) && entry.bytesize <= 4_096 }
        else false
        end
      end

      def unchanged_fixture?(value)
        return false unless INSTANCE_OF.bind_call(value, File)

        absolute = FILE_PATH.bind_call(value)
        return false unless absolute.is_a?(String)
        return false unless absolute.start_with?("#{@root}/test/fixtures/", "#{@root}/spec/fixtures/")
        return false unless absolute == File.realpath(absolute)

        path = absolute.delete_prefix("#{@root}/")
        @test_inputs.key?(path) && !@sources.key?(path)
      rescue IOError, TypeError, SystemCallError
        false
      end

      def opaque_call?(event)
        name = event.method_id
        owner = event.defined_class
        return true if PROCESS_CALLS.include?(name) && PROCESS_OWNERS.include?(owner)
        return true if INSPECTIONS[owner]&.include?(name) && project_invocation?(event.path)

        relevant = (owner == TracePoint && %i[enable disable].include?(name)) || %i[set_trace_func add_trace_func].include?(name) ||
                   (REFLECTIVE_CALLS.include?(name) && REFLECTIVE_OWNERS.include?(owner))
        relevant && project_path?(event.path)
      end

      def file_owner?(owner)
        FILE_OWNERS[owner] || (defined?(::Pathname) && owner == ::Pathname)
      end

      def project_invocation?(path)
        return true if project_path?(path)

        caller = caller_locations(2, 12).find do |frame|
          location = frame.absolute_path || frame.path
          location != __FILE__ && location != path && !location.start_with?("<internal:")
        end
        caller && project_path?(caller.absolute_path || caller.path)
      end

      def project_path?(path)
        path && !path.start_with?("<", "(") && File.expand_path(path, @root).start_with?("#{@root}/")
      end

      def relative_input(path)
        absolute = File.expand_path(path, @root)
        unless absolute.start_with?("#{@root}/") && File.realpath(absolute).start_with?("#{@root}/")
          raise ArgumentError, "reach-map requires project inputs inside the Git worktree: #{path}"
        end

        absolute.delete_prefix("#{@root}/")
      end

      def fingerprints(paths)
        absolute_paths = paths.map { |path| File.expand_path(path, @root) }
        absolute_paths.uniq.sort.select { |path| File.file?(path) }.to_h do |path|
          [relative_input(path), Digest::SHA256.file(path).hexdigest]
        end
      end

      def glob_fingerprints(patterns)
        fingerprints(Dir.glob(patterns, File::FNM_DOTMATCH, base: @root))
      end

      def boot_fingerprints
        inputs = glob_fingerprints(BOOT_INPUTS)
        @boot ? inputs.merge(fingerprints([@boot])) : inputs
      end

      def external_fingerprints
        paths = [File.join(Dir.home, ".rspec"), File.join(File.expand_path(ENV.fetch("XDG_CONFIG_HOME", "~/.config")), "rspec/options")]
        paths << Bundler.default_lockfile.to_s if defined?(Bundler) && ENV["BUNDLE_GEMFILE"]
        paths.uniq.sort.select { |path| File.file?(path) }.to_h { |path| [digest(File.expand_path(path)), Digest::SHA256.file(path).hexdigest] }
      end

      def digest(content)
        Digest::SHA256.hexdigest(content)
      end

      def atomic_write(data)
        path = File.join(@root, PATH)
        directory = File.dirname(path)
        raise ArgumentError, "reach-map requires .ripr inside the Git worktree" if File.symlink?(directory)

        FileUtils.mkdir_p(directory)
        Tempfile.create(["reach-map-", ".json"], directory) do |file|
          file.write(JSON.generate(data))
          file.flush
          file.fsync
          file.close
          File.rename(file.path, path)
        end
      end
    end
  end
end
