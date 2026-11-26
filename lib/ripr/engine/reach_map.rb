# frozen_string_literal: true

require "tempfile"
require "fileutils"
require "json"
require_relative "../core/call_graph"
require_relative "../version"

module Ripr
  module Engine
    class ReachMap
      VERSION = 1
      PATH = ".ripr/reach-map.json"
      TEST_INPUTS = %w[test/**/* spec/**/* .rspec .rspec-local].freeze
      BOOT_INPUTS = %w[config/**/* db/**/* Gemfile Gemfile.lock gems.rb gems.locked .env* .ripr.yml].freeze
      SETTINGS = %i[include exclude framework tests operators arid_callees seed samples boot rails static].freeze

      def initialize(sources, config)
        @root = Dir.pwd
        @graph = Core::CallGraph.new(sources)
        raise ArgumentError, "reach-map requires parseable project Ruby files" if sources.empty? || !@graph.structure_hash

        @sources = sources.to_h { |path, source| [relative_input(path), digest(source)] }
        @boot = config[:boot]
        @test_patterns = TEST_INPUTS + Array(config[:tests])
        @test_inputs = glob_fingerprints(@test_patterns)
        @boot_inputs = boot_fingerprints
        @runtime = { "ruby" => RUBY_DESCRIPTION, "platform" => RUBY_PLATFORM, "prism" => Prism::VERSION,
                     "ripr" => Ripr::VERSION, "environment_hash" => digest(Marshal.dump(ENV.to_a.sort)),
                     "loader" => ENV.fetch("RIPR_LOADER", nil) == "require" ? "require" : "load_iseq" }
        @settings = config.to_h.slice(*SETTINGS).transform_keys(&:to_s)
        @settings["boot"] = relative_input(@boot) if @boot
        @reach = Hash.new { |hash, id| hash[id] = {} }
        @unattributed = {}
        @unresolved_files = $LOADED_FEATURES.filter_map { |path| @graph.source_path(path) }.to_h { |path| [path, true] }
      end

      def capture(&)
        trace = TracePoint.new(:call) { |event| record(event) }
        trace.enable(&)
      end

      def observations
        { "reach" => @reach.sort.to_h.transform_values { |ids| ids.keys.sort }, "unattributed" => @unattributed.keys.sort,
          "unresolved_files" => @unresolved_files.keys.sort }
      end

      def write(result, discovered, test_files, framework, base, git)
        raise ArgumentError, "working directory changed during reach-map capture" unless Dir.pwd == @root

        tests = result.fetch("tests").transform_values { |test| test_metadata(test) }
        expected = discovered.to_h { |test| [test.fetch("id"), test_metadata(test)] }
        unless !tests.empty? && tests == expected && complete_attribution?(result.fetch("observations"), tests)
          raise BaselineFailure, "reach-map requires a complete baseline"
        end

        raise ArgumentError, "Git HEAD changed during reach-map capture" unless git.clean_head == base

        test_inputs = @test_inputs.merge(fingerprints(test_files + tests.values.map { |test| test.fetch("file") }))
        unless @sources == fingerprints(@sources.keys) && glob_fingerprints(@test_patterns) == @test_inputs &&
               boot_fingerprints == @boot_inputs
          raise ArgumentError, "project inputs changed during reach-map capture"
        end

        manifest = { "version" => VERSION, "base" => base, "project_prefix" => git.project_prefix,
                     "framework" => framework, "runtime" => @runtime, "settings" => @settings,
                     "structure_hash" => @graph.structure_hash, "method_hashes" => @graph.method_hashes, "sources" => @sources,
                     "deferred_methods" => @graph.deferred_methods, "tests" => tests, "test_order" => tests.keys,
                     "test_files" => test_inputs.sort.to_h, "boot_inputs" => @boot_inputs }
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
        observations.fetch("reach").values.all? { |ids| ids.all? { |id| tests.key?(id) } }
      end

      def test_metadata(test)
        { "file" => relative_input(test.fetch("file")), "line" => test.fetch("line") }
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
