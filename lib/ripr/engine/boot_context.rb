# frozen_string_literal: true

require "digest/sha2"
require "rbconfig"
require "securerandom"

module Ripr
  module Engine
    class BootContext
      PROJECT_INPUTS = %w[{config,db,app,lib,test,spec}/**/* Gemfile Gemfile.lock gems.rb gems.locked .env* .ripr.yml].freeze
      READS = %i[read binread readlines readline gets getc getbyte readchar readbyte readpartial read_nonblock sysread pread].freeze
      FILE_QUERIES = %i[exist? exists? file? directory? symlink? readable? writable? executable? size size? empty? realpath readlink].freeze
      DIRECTORY_QUERIES = %i[glob [] entries children pwd getwd].freeze
      FILESYSTEM = [File, IO, Dir, FileTest, File::Stat].flat_map { |type| [type, type.singleton_class] }.freeze
      FILE_HANDLES = %i[absolute_path absolute_path? expand_path dirname basename split join extname fnmatch fnmatch? path open close
                        closed? binmode set_encoding external_encoding internal_encoding].freeze
      SAFE_FILESYSTEM = (READS + FILE_QUERIES + DIRECTORY_QUERIES + FILE_HANDLES).freeze
      PROCESSES = %i[system exec fork spawn ` popen].freeze
      PROCESS_OWNERS = [Kernel, Kernel.singleton_class, Process.singleton_class, IO.singleton_class].freeze
      ARRAY_RANDOM = %i[sample shuffle shuffle!].freeze
      RUNTIME_EFFECTS = (%i[now current today new at clock_gettime random_number rand srand
                            uuid hex bytes urandom pid ppid] + ARRAY_RANDOM).freeze
      REFLECTION = %i[eval class_eval module_eval instance_eval].freeze
      NETWORK = %i[new open start connect connect_nonblock bind listen accept accept_nonblock tcp udp getaddrinfo
                   gethostbyname send recv].freeze
      ISEQ = RubyVM::InstructionSequence
      INSTRUCTION_READS = %i[disasm disassemble to_binary to_a].freeze
      CLASS_OF = Object.instance_method(:class)
      IS_A = Object.instance_method(:is_a?)
      MODULE_SUBCLASS = Module.instance_method(:<=)
      SAME = BasicObject.instance_method(:equal?)
      FILE_PATH = File.instance_method(:path)
      SCALARS = [NilClass, TrueClass, FalseClass, Integer].freeze
      RUNTIME_DIRS = %w[rubylibdir rubyarchdir sitelibdir sitearchdir vendorlibdir vendorarchdir].freeze

      def initialize(boot:, rails:, source_paths: [], root: Dir.pwd)
        @root = File.realpath(root)
        @boot = File.expand_path(boot || "config/environment.rb", @root)
        @rails = rails
        @sources = source_paths.filter_map { |path| real_file(path) }.to_h { |path| [path, true] }
        @used_sources = {}
        @scripts = {}
        @inputs = Digest::SHA256.new
        @runtime_prefixes = (RbConfig::CONFIG.values_at(*RUNTIME_DIRS) + [File.expand_path("../..", __dir__)]).filter_map do |path|
          "#{File.realpath(path)}/" if path && File.directory?(path)
        end
        @initial_features = $LOADED_FEATURES.dup
        @before_environment = environment_digest
        @observed = false
        @opaque = !project_path?(@boot)
      end

      def observe(&)
        @observed = true
        return yield if @opaque

        query_traces = []
        %i[glob []].each do |call|
          target = Dir.method(call)
          next unless target.source_location&.first == "<internal:dir>"

          query_trace = TracePoint.new(:return) { |event| inspect_event(event) unless @opaque }
          query_traces << query_trace
          query_trace.enable(target:)
        end
        trace = TracePoint.new(:call, :b_call, :c_call, :c_return, :script_compiled) do |event|
          inspect_event(event) unless @opaque
        end
        trace.enable(&)
      ensure
        query_traces&.reverse_each(&:disable)
      end

      def fingerprint(sqlite_snapshots: nil)
        return unless @observed && !@opaque && (!@rails || sqlite_snapshots)

        boot = real_file(@boot)
        return unless project_path?(boot) && @scripts.keys.all? { |path| File.file?(path) }

        features = ($LOADED_FEATURES - @initial_features).filter_map { |path| real_file(path) }
        return unless features.all? { |path| known_script?(path) }

        files = input_files(boot, features).map do |path|
          from_boot = @scripts[path]
          if @sources[path] && !@used_sources[path] && path != boot
            [path, nil]
          else
            current = digest_file(path)
            break if from_boot && from_boot != current

            [path, current]
          end
        end
        return unless files

        database = sqlite_snapshots&.map { |path| digest_file(path) }
        digest([@root, @rails, boot, files, @inputs.hexdigest, @before_environment, environment_digest, database, $LOAD_PATH.map(&:dup)])
      rescue SystemCallError, IOError, TypeError
        nil
      end

      private

      def inspect_event(event)
        case event.event
        when :script_compiled
          observe_script(event)
        when :c_return
          observe_input(event)
        when :return
          observe_query(event) if project_invocation?(event.path)
        else
          observe_source(event) unless event.event == :c_call
          @opaque = opaque_event?(event)
        end
      rescue SystemCallError, IOError, TypeError
        @opaque = true
      end

      def observe_script(event)
        if (script = event.eval_script)
          @inputs << digest(script)
        else
          iseq = event.instruction_sequence
          path = real_file(iseq.absolute_path || iseq.path)
          return unless path

          @opaque = !known_script?(path)
          @scripts[path] = digest_file(path) unless @opaque || @sources[path]
        end
      end

      def observe_source(event)
        path = event.path
        return unless path && (@sources[path] || project_path?(path))

        file = real_file(path)
        @used_sources[file] = true if @sources[file]
      end

      def observe_input(event)
        return unless FILESYSTEM.include?(event.defined_class)

        call = event.method_id
        receiver = event.self
        if READS.include?(call) && (SAME.bind_call(receiver, File) || SAME.bind_call(receiver, IO) || IS_A.bind_call(receiver, IO))
          return if call == :readpartial && IS_A.bind_call(receiver, File) && bootsnap_index?(receiver)

          @opaque = true if IS_A.bind_call(receiver, IO) && !IS_A.bind_call(receiver, File)
          record_input(call, event.return_value) unless @opaque
        elsif project_path?(event.path) && (FILE_QUERIES.include?(call) || DIRECTORY_QUERIES.include?(call))
          observe_query(event)
        end
      end

      def observe_query(event)
        call = event.method_id
        value = event.return_value
        @opaque = true if value.nil? && %i[glob [] entries children].include?(call)
        record_input(call, value) unless @opaque
      end

      def record_input(call, value)
        shape = if CLASS_OF.bind_call(value) == Array
                  value.map { |item| input_value(item) } unless value.size > 16_384
                else
                  [input_value(value)]
                end
        @opaque = !shape || shape.include?(nil)
        @inputs << digest([call, shape]) unless @opaque
      end

      def input_value(value)
        type = CLASS_OF.bind_call(value)
        return [value] if SCALARS.include?(type)
        return unless type == String

        [value.encoding.name, Digest::SHA256.hexdigest(value)]
      end

      def opaque_event?(event)
        call = event.method_id
        owner = event.defined_class
        receiver = event.self
        return true if PROCESSES.include?(call) && PROCESS_OWNERS.include?(owner)
        return true if defined?(::Socket) && NETWORK.include?(call) && socket?(receiver)
        return true if source_inspection?(event, owner, call)
        if (FILESYSTEM.include?(owner) && !SAFE_FILESYSTEM.include?(call)) || (owner == Kernel && call == :open)
          return !!project_invocation?(event.path)
        end
        return false unless RUNTIME_EFFECTS.include?(call) || REFLECTION.include?(call)
        return false unless project_invocation?(event.path)

        if REFLECTION.include?(call)
          [Kernel, Kernel.singleton_class, Module, BasicObject, Binding].include?(owner)
        else
          [Time, Process, Random, Thread, ::SecureRandom].any? { |type| SAME.bind_call(type, receiver) } ||
            (defined?(::Date) && SAME.bind_call(::Date, receiver)) || (defined?(::DateTime) && SAME.bind_call(::DateTime, receiver)) ||
            (owner == Kernel && %i[rand srand].include?(call)) || (owner == Array && ARRAY_RANDOM.include?(call))
        end
      end

      def source_inspection?(event, owner, call)
        return true if %i[set_trace_func add_trace_func].include?(call)
        return true if owner == TracePoint && %i[enable disable].include?(call)
        return true if owner == ISEQ.singleton_class && call == :of
        return true if owner == RubyVM::AbstractSyntaxTree.singleton_class && %i[of parse_file].include?(call)
        return true if defined?(Prism) && owner == Prism.singleton_class && call.to_s.end_with?("_file")
        return false unless owner == ISEQ && INSTRUCTION_READS.include?(call)

        bootsnap = Gem.loaded_specs["bootsnap"] if defined?(Gem)
        call != :to_binary || !bootsnap || event.path != File.join(bootsnap.full_gem_path, "lib/bootsnap/compile_cache/iseq.rb")
      end

      def socket?(receiver)
        return true if IS_A.bind_call(receiver, ::BasicSocket)
        return true if IS_A.bind_call(receiver, Class) && MODULE_SUBCLASS.bind_call(receiver, ::BasicSocket)

        defined?(::Addrinfo) && SAME.bind_call(receiver, ::Addrinfo)
      end

      def bootsnap_index?(file)
        return false unless File.basename(FILE_PATH.bind_call(file)) == "load-path-cache"

        gem = Gem.loaded_specs["bootsnap"] if defined?(Gem)
        return false unless gem

        store = File.join(gem.full_gem_path, "lib/bootsnap/load_path_cache/store.rb")
        caller_locations(2, 12).any? { |frame| frame.absolute_path == store && frame.base_label == "load_data" }
      end

      def project_invocation?(path)
        return true if project_path?(path)

        location = caller_locations(2, 10).find do |frame|
          candidate = frame.absolute_path || frame.path
          candidate != __FILE__ && candidate != path && !candidate.start_with?("<internal:")
        end
        location && project_path?(location.absolute_path || location.path)
      end

      def project_path?(path)
        path && !path.start_with?("<", "(") && File.expand_path(path, @root).start_with?("#{@root}/")
      end

      def known_script?(path)
        return true if project_path?(path) || path.start_with?(*@runtime_prefixes)
        return false unless defined?(Gem)

        Gem.loaded_specs.each_value.any? { |spec| spec.full_require_paths.any? { |root| path.start_with?("#{root}/") } }
      end

      def input_files(boot, features)
        project = Dir.glob(PROJECT_INPUTS, File::FNM_DOTMATCH, base: @root)
        lockfile = Bundler.default_lockfile.to_s if defined?(Bundler) && ENV["BUNDLE_GEMFILE"]
        features += @initial_features.select { |path| project_path?(path) }
        ([boot, lockfile] + project + @sources.keys + @scripts.keys + features).filter_map do |path|
          real_file(path) if path
        end.uniq.sort
      end

      def real_file(path)
        full = File.expand_path(path, @root)
        File.realpath(full) if File.file?(full)
      end

      def digest_file(path)
        Digest::SHA256.file(path).hexdigest
      end

      def environment_digest
        digest(ENV.to_a.sort)
      end

      def digest(value)
        Digest::SHA256.hexdigest(Marshal.dump(value))
      end
    end
  end
end
